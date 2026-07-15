# frozen_string_literal: true

module GoodJob
  # Handles Active Job lifecycle notifications that need to be reflected in GoodJob.
  module ActiveJobNotifications
    class << self
      def enqueue(event)
        payload = event.payload
        active_job = payload[:job]
        return unless active_job && payload[:adapter].is_a?(GoodJob::Adapter)

        error = payload[:exception_object]
        error ||= active_job.enqueue_error if active_job.respond_to?(:enqueue_error)
        return unless error
        return if active_job.provider_job_id.present?

        GoodJob::Job.record_enqueue_failure(active_job, error)
      rescue StandardError => e
        report_error(e)
      end

      private

      # Notification subscribers must not replace the original enqueue result with a
      # secondary reporting error.
      def report_error(error)
        safely_log(error)
        GoodJob._on_thread_error(error)
      rescue StandardError => e
        safely_log(e)
      end

      def safely_log(error)
        GoodJob.logger.error("GoodJob could not record an enqueue failure: #{error.class}: #{error.message}")
      rescue StandardError
        nil
      end
    end
  end
end
