require "aws-sdk"
require "thread"
require "timeout"

require "alephant/logger"

module Alephant
  module Sequencer
    class SequenceTable
      include ::Alephant::Logger

      attr_reader :table_name

      TIMEOUT = 120
      DEFAULT_CONFIG = {
        :write_units => 5,
        :read_units => 10,
      }
      SCHEMA = {
        :hash_key => {
          :key => :string,
          :value => :string
        }
      }

      def initialize(table_name, config = DEFAULT_CONFIG)
        @mutex = Mutex.new
        @dynamo_db = AWS::DynamoDB.new
        @table_name = table_name
        @config = config
      end

      def create
        @mutex.synchronize do
          ensure_table_exists
          ensure_table_active
        end
      end

      def table
        @table ||= @dynamo_db.tables[@table_name]
      end

      def sequence_exists(ident)
        !(table.items.where(:key => ident) == 0)
      end

      def sequence_for(ident)
        rows = batch_get_value_for(ident)
        rows.count >= 1 ? rows.first["value"].to_i : nil
      end

      def set_sequence_for(ident, value, last_seen_check = nil)
        begin
          @mutex.synchronize do
            table.items.put(
              {:key => ident, :value => value },
              put_condition(last_seen_check)
            )
          end

          logger.info("SequenceTable#set_sequence_for: #{value} for #{ident} success!")
        rescue AWS::DynamoDB::Errors::ConditionalCheckFailedException => e
          logger.warn("SequenceTable#set_sequence_for: #{ident} #{e.message}")
          last_seen_check = sequence_for(ident)

          unless last_seen_check >= value
            logger.info("SequenceTable#set_sequence_for: #{ident} trying again!")
            set_sequence_for(ident, value, last_seen_check)
          else
            logger.warn("SequenceTable#set_sequence_for: #{ident} outdated!")
          end
        end
      end

      def delete_item!(ident)
        table.items[ident].delete
      end

      def truncate!
        batch_delete table_data
      end

      private

      def batch_delete(rows)
        rows.each_slice(25) { |arr| table.batch_delete(arr) }
      end

      def table_data
        table.items.collect do |item|
          construct_attributes_from item
        end
      end

      def construct_attributes_from(item)
        range_key? ? [item.hash_value, item.range_value.to_i] : item.hash_value
      end

      def range_key?
        @range_found ||= table.items.first.range_value
      end

      def put_condition(last_seen_check)
        last_seen_check.nil? ? unless_exists(:key) : if_value(last_seen_check)
      end

      def batch_get_value_for(ident)
        table.batch_get(["value"],[ident],batch_get_opts)
      end

      def unless_exists(key)
        { :unless_exists => key }
      end

      def if_value(value)
        { :if => { :value => value.to_i } }
      end

      def batch_get_opts
        { :consistent_read => true }
      end

      def ensure_table_exists
        create_dynamodb_table unless table.exists?
      end

      def ensure_table_active
        sleep_until_table_active unless table_active?
      end

      def create_dynamodb_table
        @table = @dynamo_db.tables.create(
          @table_name,
          @config[:read_units],
          @config[:write_units],
          SCHEMA
        )
      end

      def table_active?
        table.status == :active
      end

      def sleep_until_table_active
        begin
          Timeout::timeout(TIMEOUT) do
            sleep 1 until table_active?
          end
        end
      end
    end
  end
end
