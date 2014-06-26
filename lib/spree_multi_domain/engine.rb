module SpreeMultiDomain
  class Engine < Rails::Engine
    engine_name 'spree_multi_domain'

    config.autoload_paths += %W(#{config.root}/lib)

    def self.activate
      ['app', 'lib'].each do |dir|
        Dir.glob(File.join(File.dirname(__FILE__), "../../#{dir}/**/*_decorator*.rb")) do |c|
          Rails.application.config.cache_classes ? require(c) : load(c)
        end
      end

      Spree::Config.searcher_class = Spree::Search::MultiDomain
      ApplicationController.send :include, SpreeMultiDomain::MultiDomainHelpers

      if Spree.user_class
        Spree.user_class.class_eval do
          def last_incomplete_order_on_store(store)
            spree_orders.incomplete.where(created_by_id: self.id, store_id: store.id).order("created_at DESC").first
          end
        end
      end
    end

    config.to_prepare &method(:activate).to_proc

    initializer "templates with dynamic layouts" do |app|
      ActionView::TemplateRenderer.class_eval do
        def find_layout_with_multi_store(layout, locals)
          store_layout = layout.is_a?(String) ? layout : layout.call

          if store_layout && @view.respond_to?(:current_store) && @view.current_store && !@view.controller.is_a?(Spree::Admin::BaseController)
            store_layout = store_layout.gsub("layouts/", "layouts/#{@view.current_store.code}/")
          end

          begin
            find_layout_without_multi_store(store_layout, locals)
          rescue ::ActionView::MissingTemplate
            find_layout_without_multi_store(layout, locals)
          end
        end

        alias_method_chain :find_layout, :multi_store
      end
    end

    initializer "current order decoration" do |app|
      require 'spree/core/controller_helpers/order'
      ::Spree::Core::ControllerHelpers::Order.module_eval do
        def current_order_with_multi_domain(options = {})
          options[:create_order_if_necessary] ||= false
          current_order_without_multi_domain(options)

          if @current_order && current_store && @current_order.store.nil?
            @current_order.update_column(:store_id, current_store.id)
          end

          @current_order
        end
        alias_method_chain :current_order, :multi_domain

        def set_current_order
          if user = try_spree_current_user
            last_incomplete_order = user.last_incomplete_order_on_store(current_store)
            if session[:order_id].nil? && last_incomplete_order
              session[:order_id] = last_incomplete_order.id
            elsif current_order(create_order_if_necessary: true) && last_incomplete_order && current_order != last_incomplete_order
              current_order.merge!(last_incomplete_order, user)
            end
          end
        end
      end
    end

    initializer 'spree.promo.register.promotions.rules' do |app|
      app.config.spree.promotions.rules << Spree::Promotion::Rules::Store
    end
  end
end
