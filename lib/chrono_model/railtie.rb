module ChronoModel
  class Railtie < ::Rails::Railtie
    initializer :chrono_create_schemas do
      ActiveRecord::Base.connection.chrono_create_schemas!
    end

    rake_tasks do
      load 'chrono_model/schema_format.rake'

      namespace :db do
        namespace :chrono do
          task :create_schemas do
            ActiveRecord::Base.connection.chrono_create_schemas!
          end
        end
      end

      task 'db:schema:load' => 'db:chrono:create_schemas'
    end
  end
end
