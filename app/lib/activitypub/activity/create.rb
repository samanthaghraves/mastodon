# frozen_string_literal: true

class ActivityPub::Activity::Create < ActivityPub::Activity
  SUPPORTED_TYPES = %w(Note).freeze
  CONVERTED_TYPES = %w(Image Video Article).freeze

  def perform
    return if delete_arrived_first?(object_uri) || unsupported_object_type? || invalid_origin?(@object['id'])
    return if AllowDomainService.blocked?(@account.domain)

    RedisLock.acquire(lock_options) do |lock|
      if lock.acquired?
        @status = find_existing_status
        process_status if @status.nil?
      end
    end

    @status
  end

  private

  def process_status
    media_attachments = process_attachments

    ApplicationRecord.transaction do
      @status = Status.create!(status_params)

      process_tags(@status)
      attach_media(@status, media_attachments)
    end

    resolve_thread(@status)
    distribute(@status)
    forward_for_reply if @status.public_visibility? || @status.unlisted_visibility?
  end

  def find_existing_status
    status   = status_from_uri(object_uri)
    status ||= Status.find_by(uri: @object['atomUri']) if @object['atomUri'].present?
    status
  end

  def status_params
    {
      uri: @object['id'],
      url: object_url || @object['id'],
      account: @account,
      text: text_from_content || '',
      language: detected_language,
      spoiler_text: @object['summary'] || '',
      created_at: @options[:override_timestamps] ? nil : @object['published'],
      reply: @object['inReplyTo'].present?,
      sensitive: @object['sensitive'] || false,
      visibility: visibility_from_audience,
      thread: replied_to_status,
      conversation: conversation_from_uri(@object['conversation']),
    }
  end

  def process_tags(status)
    return if @object['tag'].nil?

    as_array(@object['tag']).each do |tag|
      case tag['type']
      when 'Hashtag'
        process_hashtag tag, status
      when 'Mention'
        process_mention tag, status
      when 'Emoji'
        process_emoji tag, status
      end
    end
  end

  def process_hashtag(tag, status)
    return if tag['name'].blank?

    hashtag = tag['name'].gsub(/\A#/, '').mb_chars.downcase
    hashtag = Tag.where(name: hashtag).first_or_initialize(name: hashtag)

    status.tags << hashtag
  end

  def process_mention(tag, status)
    return if tag['href'].blank?

    account = account_from_uri(tag['href'])
    account = FetchRemoteAccountService.new.call(tag['href'], id: false) if account.nil?
    return if account.nil?
    account.mentions.create(status: status)
  end

  def process_emoji(tag, _status)
    return if skip_download?
    return if tag['name'].blank? || tag['icon'].blank? || tag['icon']['url'].blank?

    shortcode = tag['name'].delete(':')
    image_url = tag['icon']['url']
    uri       = tag['id']
    updated   = tag['updated']
    emoji     = CustomEmoji.find_by(shortcode: shortcode, domain: @account.domain)

    return unless emoji.nil? || emoji.updated_at >= updated

    emoji ||= CustomEmoji.new(domain: @account.domain, shortcode: shortcode, uri: uri)
    emoji.image_remote_url = image_url
    emoji.save
  end

  def process_attachments
    return if @object['attachment'].nil?

    media_attachments = []

    as_array(@object['attachment']).each do |attachment|
      next if unsupported_media_type?(attachment['mediaType']) || attachment['url'].blank?

      href             = Addressable::URI.parse(attachment['url']).normalize.to_s
      media_attachment = MediaAttachment.create(account: @account, remote_url: href, description: attachment['name'].presence)
      media_attachments << media_attachment

      next if skip_download?

      media_attachment.file_remote_url = href
      media_attachment.save
    end

    media_attachments
  rescue Addressable::URI::InvalidURIError => e
    Rails.logger.debug e

    media_attachments
  end

  def attach_media(status, media_attachments)
    return if media_attachments.blank?

    media = MediaAttachment.where(status_id: nil, id: media_attachments.take(4).map(&:id))
    media.update(status_id: status.id)
  end

  def resolve_thread(status)
    return unless status.reply? && status.thread.nil?
    ThreadResolveWorker.perform_async(status.id, in_reply_to_uri)
  end

  def conversation_from_uri(uri)
    return nil if uri.nil?
    return Conversation.find_by(id: OStatus::TagManager.instance.unique_tag_to_local_id(uri, 'Conversation')) if OStatus::TagManager.instance.local_id?(uri)
    Conversation.find_by(uri: uri) || Conversation.create(uri: uri)
  end

  def visibility_from_audience
    if equals_or_includes?(@object['to'], ActivityPub::TagManager::COLLECTIONS[:public])
      :public
    elsif equals_or_includes?(@object['cc'], ActivityPub::TagManager::COLLECTIONS[:public])
      :unlisted
    elsif equals_or_includes?(@object['to'], @account.followers_url)
      :private
    else
      :direct
    end
  end

  def audience_includes?(account)
    uri = ActivityPub::TagManager.instance.uri_for(account)
    equals_or_includes?(@object['to'], uri) || equals_or_includes?(@object['cc'], uri)
  end

  def replied_to_status
    return @replied_to_status if defined?(@replied_to_status)

    if in_reply_to_uri.blank?
      @replied_to_status = nil
    else
      @replied_to_status   = status_from_uri(in_reply_to_uri)
      @replied_to_status ||= status_from_uri(@object['inReplyToAtomUri']) if @object['inReplyToAtomUri'].present?
      @replied_to_status
    end
  end

  def in_reply_to_uri
    value_or_id(@object['inReplyTo'])
  end

  def text_from_content
    return Formatter.instance.linkify([text_from_name, object_url || @object['id']].join(' ')) if converted_object_type?

    if @object['content'].present?
      @object['content']
    elsif content_language_map?
      @object['contentMap'].values.first
    end
  end

  def text_from_name
    if @object['name'].present?
      @object['name']
    elsif name_language_map?
      @object['nameMap'].values.first
    end
  end

  def detected_language
    if content_language_map?
      @object['contentMap'].keys.first
    elsif name_language_map?
      @object['nameMap'].keys.first
    elsif supported_object_type?
      LanguageDetector.instance.detect(text_from_content, @account)
    end
  end

  def object_url
    return if @object['url'].blank?

    url_candidate = url_to_href(@object['url'], 'text/html')

    if invalid_origin?(url_candidate)
      nil
    else
      url_candidate
    end
  end

  def content_language_map?
    @object['contentMap'].is_a?(Hash) && !@object['contentMap'].empty?
  end

  def name_language_map?
    @object['nameMap'].is_a?(Hash) && !@object['nameMap'].empty?
  end

  def unsupported_object_type?
    @object.is_a?(String) || !(supported_object_type? || converted_object_type?)
  end

  def unsupported_media_type?(mime_type)
    mime_type.present? && !(MediaAttachment::IMAGE_MIME_TYPES + MediaAttachment::VIDEO_MIME_TYPES).include?(mime_type)
  end

  def supported_object_type?
    SUPPORTED_TYPES.include?(@object['type'])
  end

  def converted_object_type?
    CONVERTED_TYPES.include?(@object['type'])
  end

  def skip_download?
    return @skip_download if defined?(@skip_download)
    @skip_download ||= AllowDomainService.reject_media?(@account.domain)
  end

  def invalid_origin?(url)
    return true if unsupported_uri_scheme?(url)

    needle   = Addressable::URI.parse(url).host
    haystack = Addressable::URI.parse(@account.uri).host

    !haystack.casecmp(needle).zero?
  end

  def reply_to_local?
    !replied_to_status.nil? && replied_to_status.account.local?
  end

  def forward_for_reply
    return unless @json['signature'].present? && reply_to_local?
    ActivityPub::RawDistributionWorker.perform_async(Oj.dump(@json), replied_to_status.account_id, [@account.preferred_inbox_url])
  end

  def lock_options
    { redis: Redis.current, key: "create:#{@object['id']}" }
  end
end
