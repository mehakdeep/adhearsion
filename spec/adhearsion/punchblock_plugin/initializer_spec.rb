require 'spec_helper'

module Adhearsion
  class PunchblockPlugin
    describe Initializer do

      def initialize_punchblock options = nil
        flexmock(Initializer).should_receive(:connect)

        if options.nil?
          Adhearsion.config.punchblock do |config|
            config.platform         = :xmpp
            config.username         = "usera@127.0.0.1"
            config.password         = "1"
            config.auto_reconnect   = true
            config.host             = nil
            config.port             = nil
            config.root_domain      = nil
            config.calls_domain     = nil
            config.mixers_domain    = nil
          end
        else
          Adhearsion.config.punchblock do |config|
            config.platform       = options[:platform]        if options.include? :platform
            config.username       = options[:username]        if options.include? :username
            config.password       = options[:password]        if options.include? :password
            config.auto_reconnect = options[:auto_reconnect]  if options.include? :auto_reconnect
            config.host           = options[:host]            if options.include? :host
            config.port           = options[:port]            if options.include? :port
            config.root_domain    = options[:root_domain]     if options.include? :root_domain
            config.calls_domain   = options[:calls_domain]    if options.include? :calls_domain
            config.mixers_domain  = options[:mixers_domain]   if options.include? :mixers_domain
          end
        end

        Initializer.start
        Adhearsion.config[:punchblock]
      end

      before do
        Events.refresh!
      end

      let(:call_id)       { rand }
      let(:offer)         { ::Punchblock::Event::Offer.new.tap { |o| o.call_id = call_id } }
      let(:mock_call)     { flexmock('Call', :id => call_id).tap { |call| call.should_ignore_missing } }
      let(:mock_manager)  { flexmock 'a mock dialplan manager' }

      describe "starts the client with the default values" do
        subject { initialize_punchblock }

        it "should set properly the username value" do
          subject.username.should == 'usera@127.0.0.1'
        end

        it "should set properly the password value" do
          subject.password.should == '1'
        end

        it "should set properly the auto_reconnect value" do
          subject.auto_reconnect.should == true
        end

        it "should set properly the host value" do
          subject.host.should be_nil
        end

        it "should set properly the port value" do
          subject.port.should be_nil
        end

        it "should set properly the root_domain value" do
          subject.root_domain.should be_nil
        end

        it "should set properly the calls_domain value" do
          subject.calls_domain.should be_nil
        end

        it "should set properly the mixers_domain value" do
          subject.mixers_domain.should be_nil
        end
      end

      it "starts the client with any overridden settings" do
        overrides = {:username => 'userb@127.0.0.1', :password => '123', :auto_reconnect => false, :host => 'foo.bar.com', :port => 200, :root_domain => 'foo.com', :calls_domain => 'call.foo.com', :mixers_domain => 'mixer.foo.com'}

        flexmock(::Punchblock::Connection::XMPP).should_receive(:new).once.with(overrides).and_return do
          flexmock 'Client', :event_handler= => true
        end
        initialize_punchblock overrides
      end

      describe 'using Asterisk' do
        let(:overrides) { {:username => 'test', :password => '123', :auto_reconnect => false, :host => 'foo.bar.com', :port => 200, :root_domain => 'foo.com', :calls_domain => 'call.foo.com', :mixers_domain => 'mixer.foo.com'} }

        it 'should start an Asterisk PB connection' do
          flexmock(::Punchblock::Connection::Asterisk).should_receive(:new).once.with(overrides).and_return do
            flexmock 'Client', :event_handler= => true
          end
          initialize_punchblock overrides.merge(:platform => :asterisk)
        end
      end

      it 'should place events from Punchblock into the event handler' do
        flexmock(Events.instance).should_receive(:trigger).once.with(:punchblock, offer)
        initialize_punchblock
        Initializer.client.handle_event offer
      end

      describe "dispatching an offer" do
        before do
          initialize_punchblock
          flexmock(Adhearsion::Process).should_receive(:state_name).once.and_return process_state
          flexmock(Adhearsion.active_calls).should_receive(:from_offer).once.and_return mock_call
        end

        context "when the Adhearsion::Process is :booting" do
          let(:process_state) { :booting }

          it 'should reject a call with cause :declined' do
            mock_call.should_receive(:reject).once.with(:decline)
          end
        end

        context "when when Adhearsion::Process is in :running" do
          let(:process_state) { :running }

          it "should execute the dispatcher provided by the router" do
            controller = Class.new
            Adhearsion.router do
              route 'foobar', controller
            end
            first_route = Adhearsion.router.routes.first
            flexmock(first_route.dispatcher).should_receive(:call).once.with mock_call
          end
        end

        context "when when Adhearsion::Process is in :rejecting" do
          let(:process_state) { :rejecting }

          it 'should reject a call with cause :declined' do
            mock_call.should_receive(:reject).once.with(:decline)
          end
        end

        context "when when Adhearsion::Process is not :running, :stopping or :rejecting" do
          let(:process_state) { :foobar }

          it 'should reject a call with cause :error' do
            mock_call.should_receive(:reject).once.with(:error)
          end
        end

        after { Events.trigger_immediately :punchblock, offer }
      end

      describe "dispatching a component event" do
        let(:component)   { flexmock 'ComponentNode' }
        let(:mock_event)  { flexmock 'Event', :call_id => call_id, :source => component }

        before do
          initialize_punchblock
        end

        it "should place the event in the call's inbox" do
          component.should_receive(:trigger_event_handler).once.with mock_event
          Events.trigger_immediately :punchblock, mock_event
        end
      end

      describe "dispatching a call event" do
        let(:mock_event)  { flexmock 'Event', :call_id => call_id }
        let(:latch)       { CountDownLatch.new 1 }

        describe "with an active call" do
          before do
            initialize_punchblock
            Adhearsion.active_calls << mock_call
          end

          it "should log an error" do
            flexmock(Adhearsion::Logging.get_logger(Initializer)).should_receive(:debug).once.with("Event received for call #{call_id}: #{mock_event.inspect}")
            Events.trigger_immediately :punchblock, mock_event
          end

          it "should place the event in the call's inbox" do
            mock_call.should_receive(:<<).once.with(mock_event)
            Initializer.dispatch_call_event mock_event, latch
            latch.wait(10).should be_true
          end
        end

        describe "with an inactive call" do
          let(:mock_event) { flexmock 'Event', :call_id => call_id }

          it "should log an error" do
            flexmock(Adhearsion::Logging.get_logger(Initializer)).should_receive(:error).once.with("Event received for inactive call #{call_id}: #{mock_event.inspect}")
            Initializer.dispatch_call_event mock_event
          end
        end
      end

      context "Punchblock configuration" do
        describe "with config specified" do
          before do
            Adhearsion.config.punchblock do |config|
              config.username = 'userb@127.0.0.1'
              config.password = 'abc123'
              config.auto_reconnect = false
            end
          end

          subject do
            Adhearsion.config[:punchblock]
          end

          it "should set properly the username value" do
            subject.username.should == 'userb@127.0.0.1'
          end

          it "should set properly the password value" do
            subject.password.should == 'abc123'
          end

          it "should set properly the auto_reconnect value" do
            subject.auto_reconnect.should == false
          end
        end

      end


    end
  end
end
