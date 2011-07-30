require 'travis/notifications'

class BuildsController < ApplicationController
  respond_to :json

  # github does not currently post the payload with the correct
  # accept or content-type headers, we need to change the
  # the github-service code for this to work correctly
  skip_before_filter :verify_authenticity_token, :only => :create

  def index
    repository = Repository.find(params[:repository_id])

    respond_with(repository.builds.recent((params[:page] || 1).to_i))
  end

  def show
    build = Build.find(params[:id])

    respond_with(build)
  end

  def create
    if build = Build.create_from_github_payload(params[:payload], api_token)
      build.save!
      enqueue!(build)
      build.repository.update_attributes!(:last_build_started_at => Time.now) # TODO the build isn't actually started now
    end

    render :nothing => true
  end

  def update
    build = Build.find(params[:id])
    build.update_attributes!(params[:build])

    if build.was_started?
      trigger('build:started', build, 'msg_id' => params[:msg_id])
    elsif build.matrix_expanded?
      build.matrix.each { |child| enqueue!(child) }
      trigger('build:configured', build, 'msg_id' => params[:msg_id])
    elsif build.was_configured?
      enqueue!(build)
      trigger('build:configured', build, 'msg_id' => params[:msg_id])
    elsif build.was_finished?
      trigger('build:finished', build, 'msg_id' => params[:msg_id])
      Travis::Notifications.send_notifications(build)
    end

    render :nothing => true
  end

  def log
    build = Build.find(params[:id], :select => "id, repository_id, parent_id", :include => [:repository])

    build.append_log!(params[:build][:log]) unless build.finished?
    trigger('build:log', build, 'build' => { '_log' => params[:build][:log] }, 'msg_id' => params[:msg_id])
    render :nothing => true
  end

  protected

    def enqueue!(build)
      # FIXME OH SHI~
      Travis::Worker.class_eval do
        @queue = if build.repository.name == 'rails'
          'rails'
        elsif build.repository.name == 'proper'
          'erlang'
        else
          'builds'
        end
      end
      Resque.enqueue(Travis::Worker, json_for(:job, build))
      trigger('build:queued', build)
    end

    def trigger(event, build, data = {})
      push(event, json_for(event, build).deep_merge(data))
      trigger(event, build.parent) if event == 'build:finished' && build.parent.try(:finished?)
    end

    def json_for(event, build)
      { 'build' => build.as_json(:for => event.to_sym), 'repository' => build.repository.as_json(:for => event.to_sym) }
    end

    def push(event, data)
      Pusher[event == 'build:queued' ? 'jobs' : 'repositories'].trigger(event, data)
    end

    def api_token
      credentials = ActionController::HttpAuthentication::Basic.decode_credentials(request)
      credentials.split(':').last
    end
end
