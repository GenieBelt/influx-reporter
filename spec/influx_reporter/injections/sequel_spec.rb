# frozen_string_literal: true

require 'spec_helper'
require 'sequel'

module InfluxReporter
  RSpec.describe Injections::Sequel do
    it 'is installed' do
      reg = InfluxReporter::Injections.installed['Sequel']
      expect(reg).to_not be_nil
    end

    before do
      @db = Sequel.sqlite # in-memory db

      @db.create_table :tests do
        primary_key :id
        String :title
      end

      @db[:tests].count # warm it up
    end

    it 'traces db calls', start_without_worker: true do
      t = InfluxReporter.transaction 'Test' do
        @db[:tests].count
      end.done(true)

      expect(t.traces.length).to be 2
      expect(t.traces.last.signature).to eq 'SELECT FROM `tests`'
    end
  end
end
