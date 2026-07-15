# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Enqueue failures' do
  before do
    ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)

    stub_const 'EnqueueFailureError', Class.new(StandardError)
    stub_const 'EnqueueFailureJob', (Class.new(ActiveJob::Base) do
      class_attribute :before_enqueue_error, :after_enqueue_error

      before_enqueue do |job|
        raise job.class.before_enqueue_error if job.class.before_enqueue_error
      end

      after_enqueue do |job|
        raise job.class.after_enqueue_error if job.class.after_enqueue_error
      end

      def perform(*)
        nil
      end
    end)
  end

  it 'records a sanitized terminal job when an enqueue callback raises' do
    active_job = EnqueueFailureJob.new('sensitive argument')
    EnqueueFailureJob.before_enqueue_error = EnqueueFailureError.new('callback failed')

    expect { active_job.enqueue }.to raise_error(EnqueueFailureError, 'callback failed')

    good_job = GoodJob::Job.find_by!(active_job_id: active_job.job_id)
    expect(good_job).to have_attributes(
      status: :discarded,
      job_class: 'EnqueueFailureJob',
      error: 'EnqueueFailureError: callback failed',
      error_event: 'enqueue_failed',
      performed_at: nil,
      finished_at: be_present
    )
    expect(good_job.serialized_params).to include(
      'job_class' => 'GoodJob::EnqueueFailureRecord',
      'job_id' => active_job.job_id,
      'arguments' => [],
      'executions' => 0
    )
    expect(good_job.serialized_params.to_s).not_to include('sensitive argument')
    expect(good_job.active_job(ignore_deserialization_errors: true)).to be_nil
    expect(good_job.executions).to be_empty
    expect(good_job).not_to be_retryable
    expect { good_job.retry_job }.to raise_error(GoodJob::Job::ActionForStateMismatchError)
  end

  it 'records serialization failures without serializing the arguments again' do
    active_job = EnqueueFailureJob.new(Object.new)

    expect { active_job.enqueue }.to raise_error(ActiveJob::SerializationError)

    good_job = GoodJob::Job.find_by!(active_job_id: active_job.job_id)
    expect(good_job).to have_attributes(error_event: 'enqueue_failed', executions_count: 0)
    expect(good_job.serialized_params['arguments']).to eq([])
  end

  it 'does not record an intentionally aborted enqueue' do
    stub_const 'AbortedEnqueueJob', (Class.new(ActiveJob::Base) do
      before_enqueue { throw :abort }

      def perform
        nil
      end
    end)
    active_job = AbortedEnqueueJob.new

    expect(active_job.enqueue).to be false
    expect(GoodJob::Job.find_by(active_job_id: active_job.job_id)).to be_nil
  end

  it 'does not replace a persisted job when an after-enqueue callback raises' do
    active_job = EnqueueFailureJob.new
    EnqueueFailureJob.after_enqueue_error = EnqueueFailureError.new('after enqueue failed')

    expect { active_job.enqueue }.to raise_error(EnqueueFailureError, 'after enqueue failed')

    expect(GoodJob::Job.where(active_job_id: active_job.job_id).count).to eq(1)
    expect(GoodJob::Job.find_by!(active_job_id: active_job.job_id)).to have_attributes(
      error_event: nil,
      finished_at: nil
    )
  end

  it 'respects disabled record preservation for direct enqueues' do
    allow(GoodJob).to receive(:preserve_job_records).and_return(false)
    active_job = EnqueueFailureJob.new
    EnqueueFailureJob.before_enqueue_error = EnqueueFailureError.new('callback failed')

    expect { active_job.enqueue }.to raise_error(EnqueueFailureError)
    expect(GoodJob::Job.find_by(active_job_id: active_job.job_id)).to be_nil
  end

  it 'preserves cron enqueue failures even when general record preservation is disabled' do
    allow(GoodJob).to receive(:preserve_job_records).and_return(false)
    cron_at = Time.current.change(usec: 0)
    active_job = EnqueueFailureJob.new
    EnqueueFailureJob.before_enqueue_error = EnqueueFailureError.new('callback failed')

    GoodJob::CurrentThread.within do |current_thread|
      current_thread.cron_key = :example_cron
      current_thread.cron_at = cron_at
      expect { active_job.enqueue }.to raise_error(EnqueueFailureError)
    end

    expect(GoodJob::Job.find_by!(active_job_id: active_job.job_id)).to have_attributes(
      cron_key: 'example_cron',
      cron_at: cron_at,
      error_event: 'enqueue_failed'
    )
  end

  it 'passes enqueue failures to callable preservation policies' do
    policy_arguments = nil
    policy = lambda do |active_job, error, error_event|
      policy_arguments = [active_job, error, error_event]
      true
    end
    allow(GoodJob).to receive(:preserve_job_records).and_return(policy)
    active_job = EnqueueFailureJob.new
    enqueue_error = EnqueueFailureError.new('callback failed')
    EnqueueFailureJob.before_enqueue_error = enqueue_error

    expect { active_job.enqueue }.to raise_error(EnqueueFailureError)

    expect(policy_arguments).to eq([active_job, enqueue_error, :enqueue_failed])
    expect(GoodJob::Job.find_by(active_job_id: active_job.job_id)).to be_present
  end

  it 'does not replace the original enqueue exception when recording fails' do
    recording_error = ActiveRecord::ConnectionNotEstablished.new('database unavailable')
    reporting_error = StandardError.new('error hook unavailable')
    allow(GoodJob::Job).to receive(:record_enqueue_failure).and_raise(recording_error)
    allow(GoodJob).to receive(:_on_thread_error).and_raise(reporting_error)
    allow(GoodJob.logger).to receive(:error)
    EnqueueFailureJob.before_enqueue_error = EnqueueFailureError.new('original failure')

    expect { EnqueueFailureJob.perform_later }.to raise_error(EnqueueFailureError, 'original failure')
    expect(GoodJob).to have_received(:_on_thread_error).with(recording_error)
    expect(GoodJob.logger).to have_received(:error).with(/database unavailable/)
    expect(GoodJob.logger).to have_received(:error).with(/error hook unavailable/)
  end

  if defined?(ActiveJob::EnqueueError)
    it 'records Active Job enqueue errors that are returned instead of raised' do
      allow(GoodJob::Job).to receive(:enqueue).and_raise(ActiveJob::EnqueueError, 'adapter failed')
      active_job = EnqueueFailureJob.new

      expect(active_job.enqueue).to be false

      expect(GoodJob::Job.find_by!(active_job_id: active_job.job_id)).to have_attributes(
        error: 'ActiveJob::EnqueueError: adapter failed',
        error_event: 'enqueue_failed'
      )
    end
  end
end
