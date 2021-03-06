module Dry
  # rubocop:disable Style/MultilineBlockChain
  # rubocop:disable Metrics/MethodLength
  # rubocop:disable Metrics/CyclomaticComplexity
  # rubocop:disable Metrics/AbcSize
  # rubocop:disable Style/MethodName
  module BlackTie
    class << self
      def protocols
        @protocols ||= Hash.new { |h, k| h[k] = h.dup.clear }
      end

      def implementations
        @implementations ||= Hash.new { |h, k| h[k] = h.dup.clear }
      end
    end

    def defprotocol
      raise if BlackTie.protocols.key?(self) # DUPLICATE DEF
      raise unless block_given?

      ims = instance_methods(false)
      class_eval(&Proc.new)
      (instance_methods(false) - ims).each { |m| class_eval { module_function m } }

      singleton_class.send :define_method, :method_missing do |method, *_args|
        raise Dry::Protocol::NotImplemented.new(:method, inspect, method)
      end

      singleton_class.send :define_method, :implementation_for do |receiver|
        receiver.class.ancestors.lazy.map do |c|
          BlackTie.implementations[self].fetch(c, nil)
        end.reject(&:nil?).first
      end

      BlackTie.protocols[self].each do |method, *_| # FIXME: CHECK PARAMS CORRESPONDENCE HERE
        singleton_class.send :define_method, method do |receiver = nil, *args|
          impl = implementation_for(receiver)
          raise Dry::Protocol::NotImplemented.new(:protocol, inspect, receiver.class) unless impl
          begin
            impl[method].(*args.unshift(receiver))
          rescue NoMethodError => e
            raise Dry::Protocol::NotImplemented.new(:method, inspect, e.message)
          rescue ArgumentError => e
            raise Dry::Protocol::NotImplemented.new(:method, inspect, "#{method} (#{e.message})")
          end
        end
      end

      singleton_class.send :define_method, :respond_to? do |method|
        BlackTie.protocols[self].keys.include? method
      end
    end

    def defmethod(name, *params)
      BlackTie.protocols[self][name] = params
    end

    DELEGATE_METHOD = lambda do |klazz, (source, target)|
      klazz.class_eval do
        define_method(source, &Dry::DEFINE_METHOD.curry[target])
      end
    end

    POSTPONE_EXTEND = lambda do |target, protocol|
      TracePoint.new(:end) do |tp|
        if tp.self == protocol
          target.extend protocol
          tp.disable
        end
      end.enable
    end

    def defimpl(protocol = nil, target: nil, delegate: [], map: {})
      raise if target.nil? || !block_given? && delegate.empty? && map.empty?

      mds = normalize_map_delegates(delegate, map)

      Module.new do
        mds.each(&DELEGATE_METHOD.curry[singleton_class])
        singleton_class.class_eval(&Proc.new) if block_given? # block takes precedence
      end.tap do |mod|
        protocol ? mod.extend(protocol) : POSTPONE_EXTEND.(mod, protocol = self)

        mod.methods(false).tap do |meths|
          (BlackTie.protocols[protocol].keys - meths).each_with_object(meths) do |m, acc|
            BlackTie.Logger.warn("Implicit delegate #{protocol.inspect}##{m} to #{target}")
            DELEGATE_METHOD.(mod.singleton_class, [m] * 2)
            acc << m
          end
        end.each do |m|
          target = [target] unless target.is_a?(Array)
          target.each do |tgt|
            BlackTie.implementations[protocol][tgt][m] = mod.method(m).to_proc
          end
        end
      end
    end
    module_function :defimpl

    def self.Logger
      @logger ||= if Kernel.const_defined?('::Rails')
                    Rails.logger
                  else
                    require 'logger'
                    Logger.new($stdout)
                  end
    end

    private

    def normalize_map_delegates(delegate, map)
      [*delegate, *map].map do |e|
        case e
        when Symbol, String then [e.to_sym] * 2
        when Array then e.map(&:to_sym) if e.size == 2
        end
      end.compact
    end
    module_function :normalize_map_delegates
  end
  # rubocop:enable Style/MethodName
  # rubocop:enable Metrics/AbcSize
  # rubocop:enable Metrics/CyclomaticComplexity
  # rubocop:enable Metrics/MethodLength
  # rubocop:enable Style/MultilineBlockChain
end
