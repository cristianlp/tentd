module TentD
  module Model
    class Mention < Sequel::Model(:mentions)
      many_to_one :post
      many_to_one :post_version # TODO: should to many to many
    end
  end
end

# module TentD
#   module Model
#     class XMention
#       include DataMapper::Resource
#
#       storage_names[:default] = "mentions"
#
#       property :id, Serial
#       property :entity, Text, :lazy => false, :required => true
#       property :original_post, Boolean, :default => false
#       property :mentioned_post_id, String
#
#       belongs_to :post, 'TentD::Model::Post', :required => false
#       belongs_to :post_version, 'TentD::Model::PostVersion', :required => false
#
#       validates_presence_of :post_id, :if => lambda { |m| m.post_version_id.nil? }
#       validates_presence_of :post_version_id, :if => lambda { |m| m.post_id.nil? }
#     end
#   end
# end
