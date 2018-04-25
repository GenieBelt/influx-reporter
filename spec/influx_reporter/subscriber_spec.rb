# frozen_string_literal: true

require 'spec_helper'

module InfluxReporter
  RSpec.describe Subscriber do
    let(:config) { Configuration.new }
    let(:client) { Client.new config }

    subject do
      Subscriber.new config, client
    end

    describe '#register!' do
      it 'subscribes to ActiveSupport::Notifications' do
        expect(ActiveSupport::Notifications).to receive(:subscribe)
        subject.register!
      end
      it 'unregisters first if already registered' do
        subject.register!
        expect(subject).to receive(:unregister!)
        expect(ActiveSupport::Notifications).to receive(:subscribe)
        subject.register!
      end
    end

    describe '#unregister' do
      it 'unsubscribes to AS::Notifications' do
        expect(ActiveSupport::Notifications).to receive(:unsubscribe)
        subject.register!
        subject.unregister!
      end
    end

    describe 'ActiveSupport::Notifications API', start_without_worker: true do
      let(:message_args) do
        [
          'process_action.action_controller',
          nil,
          { controller: 'Controller', action: 'index' }
        ]
      end
      describe '#start' do
        it 'adds a new notification to current transaction' do
          transaction = InfluxReporter.transaction 'Test'

          expect do
            subject.start(*message_args)
          end.to change(transaction.notifications, :length).by 1

          transaction.release
        end
      end

      describe '#finish' do
        it 'adds a trace to current transaction' do
          transaction = InfluxReporter.transaction 'Test'

          expect do
            subject.start(*message_args)
            subject.finish(*message_args)
          end.to change(transaction.traces, :length).by 1

          transaction.release
        end
        it 'adds a stack of parents', mock_time: true do
          transaction = InfluxReporter.transaction 'Rack' do
            subject.start(*message_args)
            travel 100
            InfluxReporter.trace('thing-1') do
              travel 100
            end
            travel 100
            subject.finish(*message_args)
          end.done(200)

          expect(transaction.traces.length).to eq 3
          expect(transaction.traces.last.parents.map(&:signature)).to eq ['transaction', 'Controller#index']
        end
      end
    end
  end
end
