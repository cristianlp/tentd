require 'securerandom'

module TentD
  module Model
    class Post < Sequel::Model(:posts)
      DELETED_POST_TYPE = TentType.new('https://tent.io/types/post/delete/v0.1.0')

      include RandomPublicId
      include Serializable
      include TypeProperties
      include Permissible
      include PermissiblePost

      plugin :paranoia
      plugin :serialization
      serialize_attributes :pg_array, :licenses
      serialize_attributes :json, :content, :views

      one_to_many :permissions
      one_to_many :attachments, :class => 'TentD::Model::PostAttachment'
      one_to_many :mentions
      one_to_many :versions, :class => 'TentD::Model::PostVersion'

      many_to_one :app
      many_to_one :following
      many_to_one :user

      def before_create
        self.public_id ||= random_id
        self.user_id ||= User.current.id
        self.received_at ||= Time.now
        self.published_at ||= Time.now
        super
      end

      def before_save
        self.updated_at = Time.now
        super
      end

      def after_create
        create_version!
        super
      end

      def self.public_attributes
        [:app_name, :app_url, :entity, :type, :licenses, :content, :published_at]
      end

      def self.write_attributes
        public_attributes + [:following_id, :original, :public, :mentions, :views]
      end

      def self.propagate_entity(user_id, entity, old_entity = nil)
        where(:original => true, :user_id => user_id).update(:entity => entity)
        Mention.from(:mentions, :posts).where(:posts__user_id => user_id, :mentions__entity => old_entity).update(:entity => entity) if old_entity
      end

      def self.create(data, options={})
        if data[:published_at] && ((data[:published_at].to_time.to_i - Time.now.to_i) > 1000000000)
          # time given in milliseconds instead of seconds
          data[:published_at] = Time.at(data[:published_at].to_time.to_i / 1000) 
        end

        mentions = data.delete(:mentions)
        post = super(data)

        mentions.to_a.uniq.each do |mention|
          next unless mention[:entity]
          mention = Mention.create(
            :post_id => post.id,
            :entity => mention[:entity],
            :mentioned_post_id => mention[:post],
            :original_post => post.original,
          )
          mention.db[:post_versions_mentions].insert(
            :post_version_id => post.latest_version(:fields => [:id]).id,
            :mention_id => mention.id
          )
        end

        if post.mentions_dataset.any? && post.original && !options[:dont_notify_mentions]
          post.notify_mentions
        end

        post
      end

      def update(data, attachments = nil)
        mentions = data.delete(:mentions)
        last_version = latest_version(:fields => [:id])

        res = super(data)
        create_version!

        current_version = latest_version(:fields => [:id])

        if mentions_dataset.any?
          query = <<SQL
          INSERT INTO post_versions_mentions (mention_id, post_version_id)
          SELECT mentions.id AS mention_id, ? AS post_version_id
          FROM mentions
          WHERE mentions.post_id = ?;
SQL
          mentions_dataset.db[:post_versions_mentions].with_sql(query, latest_version.id, id).insert
          mentions_dataset.where(:post_id => id).count
          mentions_dataset.update(:post_id => nil)
          mentions.to_a.each do |mention|
            next unless mention[:entity]
            m = Mention.create(
              :post_id => self.id,
              :entity => mention[:entity],
              :mentioned_post_id => mention[:post],
              :original_post => self.original,
            )
            Mention.db[:post_versions_mentions].insert(
              :mention_id => m.id,
              :post_version_id => current_version.id
            )
          end
        end

        res
      end

      def notify_mentions(post_id = self.id)
        mentions.each do |mention|
          follower = Follower.first(:user_id => User.current.id, :entity => mention.entity)
          next if follower && NotificationSubscription.first(:user_id => User.current.id, :follower => follower, :type_base => self.type.base)

          Notifications.notify_entity(:entity => mention.entity, :post_id => post_id)
        end
      end

      def public_mentions(params = {})
        sql = []
        sql_bindings = []

        sql << "SELECT posts.public_id AS mentioned_post_id, posts.entity, posts.type_base, posts.type_version FROM mentions"
        sql << "INNER JOIN posts ON posts.id = mentions.post_id"

        sql << "WHERE mentions.mentioned_post_id = ?"
        sql_bindings << public_id

        sql << "AND mentions.entity = ?"
        sql_bindings << entity

        sql << "AND posts.user_id = ?"
        sql_bindings << user_id

        sql << "AND posts.public = ?"
        sql_bindings << true

        if params.has_key?(:before_id)
          sql << "AND posts.id < ?"
          sql_bindings << params[:before_id]
        end

        if params.has_key?(:until_id)
          sql << "AND posts.id < ?"
          sql_bindings << params[:until_id]
        end

        if params.has_key?(:since_id)
          sql << "AND posts.id > ?"
          sql_bindings << params[:since_id]
        end

        if params[:post_types]
          sql << "AND posts.type_base IN ?"
          sql_bindings << params[:post_types].split(',').map { |uri| TentType.new(uri).base }
        end

        if params.has_key?(:before_id)
          sort_reversed = true
          sort_direction = 'DESC'
        else
          sort_reversed = false
          sort_direction = 'ASC'
        end

        sql << "ORDER BY posts.id #{sort_direction}"

        sql << "LIMIT ?"
        sql_bindings << [(params[:limit] ? params[:limit].to_i : API::PER_PAGE), API::MAX_PER_PAGE].min

        sql = sql.join(' ')

        query = Mention.with_sql(sql, *sql_bindings)
        if params[:return_count]
          query.count
        else
          res = query.all
          res.reverse! if sort_reversed
          res
        end
      end

      def latest_version(options = {})
        q = versions_dataset
        if fields = options.delete(:fields)
          q = q.select(*fields)
        end
        q.order(:version.desc).first(options)
      end

      def create_version!(post = self)
        attrs = post.attributes
        attrs.delete(:id)
        latest = post.versions_dataset.select(:version).order(:version.desc).first
        attrs[:version] = latest ? latest.version + 1 : 1
        version = PostVersion.create(attrs.merge(:post_id => post.id))
      end

      def can_notify?(app_or_follow)
        return true if public && original
        case app_or_follow
        when AppAuthorization
          (app_or_follow.scopes && app_or_follow.scopes.map(&:to_sym).include?(:read_posts)) ||
          (app_or_follow.post_types && app_or_follow.post_types.include?(type.base))
        when Follower
          return false unless original
          q = permissions_dataset
          if app_or_follow.groups.any?
            q = q.where({ :follower_access_id => app_or_follow.id, :group_public_id => app_or_follow.groups }.sql_or)
          else
            q = q.where(:follower_access_id => app_or_follow.id)
          end
          q.any?
        when Following
          return false unless original
          q = permissions_dataset
          if app_or_follow.groups.any?
            q = q.where({ :following => app_or_follow, :group_public_id => app_or_follow.groups }.sql_or)
          else
            q = q.where(:following => app_or_follow)
          end
          q.any?
        else
          false
        end
      end

      def as_json(options = {})
        attributes = super
        attributes[:type] = type.uri
        attributes[:version] = latest_version(:fields => [:version]).version

        app_name, app_url = attributes.delete(:app_name), attributes.delete(:app_url)
        if app_name || app_url
          attributes[:app] = {}
          attributes[:app][:name] = app_name if app_name
          attributes[:app][:url] = app_url if app_url
        end

        attributes[:mentions] = mentions.map do |mention|
          h = { :entity => mention.entity }
          h[:post] = mention.mentioned_post_id if mention.mentioned_post_id
          h
        end

        Array(options[:exclude]).each { |k| attributes.delete(k) if k }
        attributes
      end
    end
  end
end
