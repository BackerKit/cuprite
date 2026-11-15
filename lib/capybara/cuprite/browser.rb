# frozen_string_literal: true

require "capybara/cuprite/browser/extensions"

module Capybara
  module Cuprite
    class Browser < Ferrum::Browser
      include Extensions

      RESET_MODES = %i[hard soft].freeze
      STORAGE_TYPES = %w[local_storage indexeddb service_workers cache_storage file_systems].join(",")

      def initialize(options = nil)
        device = options&.dig(:emulate)
        options = Devices.fetch(device).except(:user_agent).merge(options) if device
        super(options&.except(:js_errors, :pending_connection_errors))

        @options.raise_on_js_errors = options&.dig(:js_errors)
        @options.raise_on_pending_connections = options.nil? || options.fetch(:pending_connection_errors, true)
        @options.raise_on_unhandled_modal = options&.dig(:raise_on_unhandled_modal)
        @options.url_blacklist = prepare_wildcards(options&.dig(:url_blacklist))
        @options.url_whitelist = prepare_wildcards(options&.dig(:url_whitelist))
        @options.reset_mode = prepare_reset_mode(options&.dig(:reset))

        @page = nil
        @reset_target_id = nil
      end

      def command(...)
        super
      rescue Ferrum::DeadBrowserError
        restart
        raise
      end

      def page
        raise Ferrum::NoSuchPageError if @page_closed

        @page ||= attach_page
      end

      def reset
        @options.reset_window_size
        forget_page
        @options.reset_mode == :soft ? soft_reset : hard_reset
      ensure
        @options.reset_window_size
        forget_page
      end

      def quit
        super
        forget_page
        @reset_target_id = nil
      end

      def resize(**options)
        @options.window_size = [options[:width], options[:height]]
        super
      end

      def current_window_handle
        page.target_id
      end

      def window_handles
        targets.values.select(&:page?).map(&:id)
      end

      def open_new_window
        attach_page(default_context.create_target.id)
      end

      def switch_to_window(target_id)
        target = window_target(target_id)
        forget_page
        @page = attach_page(target.id)
        @page.activate
      end

      def close_window(target_id)
        target = window_target(target_id)
        if @page&.target_id == target.id
          forget_page
          @page_closed = true
        end
        target.page.close
        targets.delete(target_id) # page.close is async, delete target asap
      end

      private

      def forget_page
        @page = nil
        @page_closed = false
      end

      def hard_reset
        @reset_target_id = nil
        contexts.reset
      end

      def soft_reset
        context = default_context
        origins = visited_origins(context)
        target = context.create_target
        close_other_contexts(context)
        close_pages(context, except: target)
        command("Storage.clearCookies", browserContextId: context.id)
        page = attach_page(target.id)
        origins.each { |o| page.command("Storage.clearDataForOrigin", origin: o, storageTypes: STORAGE_TYPES) }
        @reset_target_id = target.id
      rescue Ferrum::Error
        hard_reset
      end

      def visited_origins(context)
        pages = context.targets.values.select(&:page?)
        urls = pages.map(&:url)
        urls += pages.select(&:connected?).flat_map { |t| t.page.network.traffic.map(&:url) }
        urls.filter_map { |url| origin(url) }.uniq
      end

      def origin(url)
        uri = URI.parse(url.to_s)
        return unless %w[http https].include?(uri.scheme) && uri.host

        port = ":#{uri.port}" unless uri.port == uri.default_port
        "#{uri.scheme}://#{uri.host}#{port}"
      rescue URI::InvalidURIError
        nil
      end

      def close_other_contexts(context)
        contexts.each.map { |id, _| id }.each { |id| contexts.dispose(id) unless id == context.id }
      end

      def close_pages(context, except:)
        context.targets.values.select(&:page?).each do |target|
          next if target.id == except.id

          target.close_connection
          command("Target.closeTarget", targetId: target.id)
          context.delete_target(target.id)
        end
      end

      def prepare_reset_mode(mode)
        mode ||= :hard
        return mode if RESET_MODES.include?(mode)

        raise ArgumentError, "reset must be one of #{RESET_MODES.inspect}, got #{mode.inspect}"
      end

      def window_target(target_id)
        target = targets[target_id]
        raise Ferrum::NoSuchPageError unless target&.page?

        target
      end

      def attach_page(target_id = nil)
        target_id ||= @reset_target_id
        target = targets[target_id] if target_id
        target ||= default_context.default_target
        return target.page if target.connected?

        target.maybe_sleep_if_new_window
        target.page = Page.new(target.client, context_id: target.context_id, target_id: target.id)
        target.page
      end
    end
  end
end
