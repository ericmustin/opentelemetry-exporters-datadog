# frozen_string_literal: true

# Copyright 2019 OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'ddtrace/span'
require 'ddtrace/ext/http'
require 'ddtrace/ext/app_types'
require 'ddtrace/contrib/redis/ext'
require 'opentelemetry/trace/status'
require 'ddtrace/distributed_tracing/headers/headers'

module OpenTelemetry
  module Exporters
    module Datadog
      class Exporter
        # @api private
        class SpanEncoder
          ENV_KEY = 'env'
          VERSION_KEY = 'version'
          DD_ORIGIN = '_dd_origin'
          AUTO_REJECT = 0
          AUTO_KEEP = 1
          USER_KEEP = 2
          SAMPLE_RATE_METRIC_KEY = '_sample_rate'
          SAMPLING_PRIORITY_KEY = '_sampling_priority_v1'
          TRUNCATION_HELPER = ::Datadog::DistributedTracing::Headers::Headers.new({})

          INSTRUMENTATION_SPAN_TYPES = {
            'OpenTelemetry::Adapters::Ethon' => ::Datadog::Ext::HTTP::TYPE_OUTBOUND,
            'OpenTelemetry::Adapters::Excon' => ::Datadog::Ext::HTTP::TYPE_OUTBOUND,
            'OpenTelemetry::Adapters::Faraday' => ::Datadog::Ext::HTTP::TYPE_OUTBOUND,
            'OpenTelemetry::Adapters::Net::HTTP' => ::Datadog::Ext::HTTP::TYPE_OUTBOUND,
            'OpenTelemetry::Adapters::Rack' => ::Datadog::Ext::HTTP::TYPE_INBOUND,
            'OpenTelemetry::Adapters::Redis' => ::Datadog::Contrib::Redis::Ext::TYPE,
            'OpenTelemetry::Adapters::RestClient' => ::Datadog::Ext::HTTP::TYPE_OUTBOUND,
            'OpenTelemetry::Adapters::Sidekiq' => ::Datadog::Ext::AppTypes::WORKER,
            'OpenTelemetry::Adapters::Sinatra' => ::Datadog::Ext::HTTP::TYPE_INBOUND
          }.freeze

          def translate_to_datadog(otel_spans, service, env = nil, version = nil, tags = nil) # rubocop:disable Metrics/AbcSize
            datadog_spans = []

            default_tags = get_default_tags(tags) || {}

            otel_spans.each do |span|
              trace_id, span_id, parent_id = get_trace_ids(span)
              span_type = get_span_type(span)

              datadog_span = ::Datadog::Span.new(nil, span.name,
                                                 service: service,
                                                 trace_id: trace_id,
                                                 parent_id: parent_id,
                                                 resource: get_resource(span),
                                                 span_type: span_type)

              # span_id is autogenerated so have to override
              datadog_span.span_id = span_id
              datadog_span.start_time = span.start_timestamp
              datadog_span.end_time = span.end_timestamp

              # set span.error, span tag error.msg/error.type
              if span.status && span.status.canonical_code != OpenTelemetry::Trace::Status::OK
                datadog_span.status = 1

                exception_type, exception_msg, exception_stack = get_exception_info(span)

                datadog_span.set_tag('error.type', exception_type)
                datadog_span.set_tag('error.msg', exception_msg)
                datadog_span.set_tag('error.stack', exception_stack)
              end

              # set tags
              span.attributes&.keys&.each do |attribute|
                datadog_span.set_tag(attribute, span.attributes[attribute])
              end

              # set default tags
              default_tags&.keys&.each do |attribute|
                datadog_span.set_tag(attribute, span.attributes[attribute])
              end

              origin = get_origin_string(span.tracestate)
              datadog_span.set_tag(DD_ORIGIN, origin) if origin && parent_id.zero?
              datadog_span.set_tag(VERSION_KEY, version) if version && parent_id.zero?
              datadog_span.set_tag(ENV_KEY, env) if env

              # TODO: In other languages, spans that aren't sampled don't get passed to
              # on_finish. Is this the case with ruby?
              sampling_rate = get_sampling_rate(span)

              datadog_span.set_metric(SAMPLE_RATE_METRIC_KEY, sampling_rate) if sampling_rate

              datadog_spans << datadog_span
            end

            datadog_spans
          end

          def int64(hex_string, base)
            TRUNCATION_HELPER.value_to_id(hex_string, base)
          end

          private

          def get_trace_ids(span)
            trace_id = int64(span.trace_id, 16)
            span_id = int64(span.span_id, 16)
            parent_id = int64(span.parent_span_id, 16) || 0

            [trace_id, span_id, parent_id]
          rescue StandardError => e
            OpenTelemetry.logger.debug("error encoding trace_ids #{e.message}")
            [0, 0, 0]
          end

          def get_span_type(span)
            # Get Datadog span type
            return unless span.instrumentation_library

            instrumentation_name = span.instrumentation_library.name
            INSTRUMENTATION_SPAN_TYPES[instrumentation_name]
          end

          def get_exception_info(span)
            # Parse span exception type, msg, and stack from span events
            error_event = span&.events&.find { |ev| ev.name == 'error' }

            return ['','',''] unless error_event

            err_type = error_event.attributes['error.type']
            err_msg = error_event.attributes['error.msg']
            err_stack = error_event.attributes['error.stack']

            [err_type, err_msg, err_stack]
          rescue StandardError => exception
            OpenTelemetry.logger.debug("error on exception info from span events: #{span.events} , #{exception.message}")
            ['','','']
          end

          def get_resource(span)
            # Get resource name for http related spans
            # TODO: how to handle resource naming for broader span types, ie db/cache/queue etc

            if span.attributes.key?('http.method')
              route = span.attributes['http.route'] || span.attributes['http.target']

              return span.attributes['http.method'] + ' ' + route if route

              return span.attributes['http.method']
            end

            span.name
          rescue StandardError => e
            OpenTelemetry.logger.debug("error encoding trace_ids #{e.message}")
            span.name
          end

          def get_sampling_rate(span)
            if span.trace_flags&.sampled?
              # TODO: expose probability sampling rate of active tracer in SpanData
              # tenatively it would be in tracestate?
              1
            else
              0
            end
          end

          def get_origin_string(tracestate)
            return if tracestate.nil? || tracestate.index(DD_ORIGIN).nil?

            # Depending on the edge cases in tracestate values this might be
            # less efficient than mapping string => array => hash.
            origin_value = tracestate.match(ORIGIN_REGEX)
            return if origin_value.nil?

            origin_value[1]
          rescue StandardError => e
            OpenTelemetry.logger.debug("error getting origin from trace state, #{e.message}")
          end

          def get_default_tags(tags)
            # Parse a string of tags typically provided via environment variables.
            # The expected string is of the form: "key1:value1,key2:value2"

            return {} if tags.nil?

            tag_map = tags.split(',').map { |kv| kv.split(':') }.to_h

            if tag_map.keys&.index('') || tag_map.values&.index('') || tag_map.values&.any? { |v| v.ends_with?(':') }
              OpenTelemetry.logger.debug("malformed tag in default tags: #{tags}")
              {}
            else
              tag_map
            end
          end
        end
      end
    end
  end
end
