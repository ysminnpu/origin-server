module ActionDispatch::Routing
  class Mapper

    def openshift_console(*args)
      opts = args.extract_options!
      openshift_console_routes
      openshift_authentication_routes
      openshift_billing_routes
      openshift_account_routes unless (Array(opts[:skip]).include? :account || Console.config.disable_account)
      root :to => 'console_index#index', :via => :get, :as => :console
    end

    protected

      def openshift_console_routes
        match 'help' => 'console_index#help', :via => :get, :as => 'console_help'
        match 'unauthorized' => 'console_index#unauthorized', :via => :get, :as => 'unauthorized'

        # Application specific resources
        resources :application_types, :only => [:show, :index], :id => /[^\/]+/
        resources :applications do
          resources :cartridges, :only => [:show, :create, :index], :id => /[^\/]+/
          resources :aliases, :only => [:show, :create, :index, :destroy, :update], :id => /[^\/]+/ do
            get :delete
          end
          resources :cartridge_types, :only => [:show, :index], :id => /[^\/]+/
          resource :restart, :only => [:show, :update], :id => /[^\/]+/

          resource :building, :controller => :building, :id => /[^\/]+/, :only => [:show, :new, :destroy, :create] do
            get :delete
          end

          resource :scaling, :controller => :scaling, :only => [:show, :new] do
            get :delete
            resources :cartridges, :controller => :scaling, :only => [:update], :id => /[^\/]+/, :format => false #, :format => /json|csv|xml|yaml/
          end

          resource :storage, :controller => :storage, :only => [:show] do
            resources :cartridges, :controller => :storage, :only => [:update], :id => /[^\/]+/, :format => false #, :format => /json|csv|xml|yaml/
          end

          member do
            get :delete
            get :get_started
          end
        end
      end

      def openshift_billing_routes
        # Billing specific resources
        resource :billing, :only => [:new, :show, :create]
      end

      def openshift_account_routes
        # Account specific resources
        resource :account, :controller => :account, :only => [:show] do
          get 'password' => 'account#password'
          post 'password' => 'account#update_password'
        end

        scope 'account' do
          openshift_account_resource_routes
        end
      end

      def openshift_account_resource_routes
        resource :domain, :only => [:new, :create, :edit, :update]
        resources :keys, :only => [:new, :create, :destroy]
        resources :authorizations, :except => [:index]
        match 'authorizations' => 'authorizations#destroy_all', :via => :delete
      end
      def openshift_authentication_routes
        # Authentication specific resources
        resource :authentication, :only => [:new]

        match 'signin' => 'authentication#signin', :via => :get, :format => false
        match 'signout' => 'authentication#signout', :via => :get, :format => false
        match 'auth' => 'authentication#auth', :via => :post, :format => false

        match 'password_reset/*token' => 'authentication#change_password', :via => :get, :format => false

        scope 'password' do
          get 'change/*token' => 'authentication#change_password', :format => false
          post 'reset' => 'authentication#send_token', :format => false
          post 'update' => 'authentication#update_password', :format => false
        end
      end      
  end
end
