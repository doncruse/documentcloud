# The public DocumentCloud API.
class ApiController < ApplicationController
  include DC::Access
  include DC::Search::Controller

  layout 'workspace'

  before_filter :bouncer if Rails.env.staging?
  before_filter :prefer_secure, :only => [:index]

  skip_before_filter :verify_authenticity_token

  before_filter :api_login_required, :only => [:upload, :projects, :update, :destroy, :projects, :create_project, :update_project, :destroy_project]
  before_filter :api_login_optional, :only => [:documents, :search, :notes]

  def index
    redirect_to '/help/api'
  end

  def search
    if mentions = params[:mentions] && params[:mentions].to_i
      mentions = 10  if mentions > 10
      mentions = nil if mentions < 1
    end
    respond_to do |format|
      format.any(:js, :json) do
        perform_search :include_facets => (params[:entities] ? :api : false), :mentions => mentions
        @response = ActiveSupport::OrderedHash.new
        @response['total']     = @query.total
        @response['page']      = @query.page
        @response['per_page']  = @query.per_page
        @response['q']         = params['q']
        @response['documents'] = @documents.map {|d| d.canonical(API_OPTIONS) }
        @response['entities']  = @query.facets if params[:entities]
        json_response
      end
    end
  end

  # Upload API, similar to our internal upload API for starters. Parameters:
  # file, title, access, source, description.
  def upload
    secure_silence_logs do
      return bad_request unless params[:file] && params[:title] && current_account
      if !params[:file].respond_to? :path
        return render({
          :json => {:message => "The file parameter must be the contents of a file."},
          :status => 400
        })
      end
      @response = Document.upload(params, current_account, current_organization).canonical
      json_response
    end
  end

  # Retrieve a document's canonical JSON.
  def documents
    return bad_request unless params[:id] and request.format.json? || request.format.js?
    return not_found unless current_document
    @response = {'document' => current_document.canonical(:access => true, :sections => true, :annotations => true)}
    json_response
  end
  
  # Retrieve a note's canonical JSON.
  def note
    return bad_request unless params[:id] and request.format.json? || request.format.js?
    return not_found unless current_note
    @response = {'annotation' => current_note.canonical}
    json_response
  end

  # Retrieve the entities for a document.
  def entities
    return bad_request unless params[:id] and request.format.json? || request.format.js?
    return not_found unless current_document
    @response = {'entities' => current_document.ordered_entity_hash}
    json_response
  end

  def update
    return bad_request unless params[:id] and request.format.json? || request.format.js?
    return not_found unless doc = current_document
    attrs = pick(params, :access, :title, :description, :source, :related_article, :published_url)
    attrs[:access] = ACCESS_MAP[attrs[:access].to_sym] if attrs[:access]
    success = doc.secure_update attrs, current_account
    return json(doc, 403) unless success
    expire_page doc.canonical_cache_path if doc.cacheable?
    @response = {'document' => doc.canonical(:access => true, :sections => true, :annotations => true)}
    json_response
  end

  def destroy
    return bad_request unless request.delete?
    return not_found   unless doc = current_document
    return forbidden   unless current_account && current_account.owns_or_collaborates?(doc)
    doc.destroy
    json nil
  end

  # Retrieve a listing of your projects, including document id.
  def projects
    @response = {'projects' => Project.accessible(current_account).map {|p| p.canonical } }
    json_response
  end

  def create_project
    attrs = pick(params, :title, :description)
    attrs[:document_ids] = (params[:document_ids] || []).map(&:to_i)
    @response = {'project' => current_account.projects.create(attrs).canonical}
    json_response
  end

  def update_project
    data = pick(params, :title, :description, :document_ids)
    ids  = (data.delete(:document_ids) || []).map(&:to_i)
    docs = Document.accessible(current_account, current_organization).all(:conditions => {:id => ids}, :select => 'id')
    current_project.set_documents(docs.map(&:id))
    current_project.update_attributes data
    @response = {'project' => current_project.reload.canonical}
    json_response
  end

  def destroy_project
    current_project.destroy
    json nil
  end

  # Allow logging of all actions, apart from secure uploads.
  def logger
    params[:secure] ? nil : super
  end


  private

  def secure_silence_logs
    if params[:secure]
      Rails.logger.silence { yield }
    else
      yield
    end
  end

  def current_project
    @current_project ||= current_account.projects.find(params[:id].to_i)
  end

  def current_document
    @current_document ||= Document.accessible(current_account, current_organization).find_by_id(params[:id].to_i)
  end

  def current_note
    if current_account
      @current_note ||= Annotation.accessible(current_account).find_by_id(params[:note_id].to_i)
    else
      @current_note ||= Annotation.unrestricted.find_by_id(params[:note_id].to_i)
    end
  end

end