require 'json'

module TentD
  class API
    module Router
      class SerializeResponse
        def call(env)
          response = if env.response
            env.response.kind_of?(String) ? env.response : serialize_response(env, env.response)
          end
          raise StandardError.new(env.response.class.name) if response =~ /#<TentD/
          status = env['response.status'] || (response ? 200 : 404)
          headers = if env['response.type'] || status == 200 && response && !response.empty?
                      { 'Content-Type' => env['response.type'] || MEDIA_TYPE } 
                    else
                      {}
                    end
          [status, headers, [response.to_s]]
        end

        private

        def serialize_response(env, object)
          if object.kind_of?(Array)
            r = object.map { |i| i.as_json(serialization_options(env)) }
            r.to_json
          else
            object.to_json(serialization_options(env))
          end
        end

        def serialization_options(env)
          {
            :app => env.current_auth.kind_of?(Model::AppAuthorization),
            :authorization_token => env.authorized_scopes.include?(:read_apps),
            :permissions => env.authorized_scopes.include?(:read_permissions),
            :groups => env.authorized_scopes.include?(:read_groups),
            :mac => env.authorized_scopes.include?(:read_secrets),
            :self => env.authorized_scopes.include?(:self),
            :auth_token => env.authorized_scopes.include?(:authorization_token),
            :view => env.params.view
          }
        end
      end
    end
  end
end
