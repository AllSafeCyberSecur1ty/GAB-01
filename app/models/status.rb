# frozen_string_literal: true
# == Schema Information
#
# Table name: statuses
#
#  id                     :bigint(8)        not null, primary key
#  uri                    :string
#  text                   :text             default(""), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  in_reply_to_id         :bigint(8)
#  reblog_of_id           :bigint(8)
#  url                    :string
#  sensitive              :boolean          default(FALSE), not null
#  visibility             :integer          default("public"), not null
#  spoiler_text           :text             default(""), not null
#  reply                  :boolean          default(FALSE), not null
#  language               :string
#  conversation_id        :bigint(8)
#  local                  :boolean
#  account_id             :bigint(8)        not null
#  application_id         :bigint(8)
#  in_reply_to_account_id :bigint(8)
#  poll_id                :bigint(8)
#  group_id               :integer
#  quote_of_id            :bigint(8)
#  revised_at             :datetime
#  markdown               :text
#  expires_at             :datetime
#  has_quote              :boolean
#

class Status < ApplicationRecord
  before_destroy :unlink_from_conversations

  include Paginable
  include Cacheable
  include StatusThreadingConcern

  # If `override_timestamps` is set at creation time, Snowflake ID creation
  # will be based on current time instead of `created_at`
  attr_accessor :override_timestamps

  update_index('statuses#status', :proper) if Chewy.enabled?

  enum visibility: [
    :public,
    :unlisted,
    :private,
    :limited,
    :private_group,
  ], _suffix: :visibility

  belongs_to :application, class_name: 'Doorkeeper::Application', optional: true

  belongs_to :account, inverse_of: :statuses
  belongs_to :in_reply_to_account, foreign_key: 'in_reply_to_account_id', class_name: 'Account', optional: true
  belongs_to :conversation, optional: true
  belongs_to :preloadable_poll, class_name: 'Poll', foreign_key: 'poll_id', optional: true
  belongs_to :group, optional: true

  belongs_to :thread, foreign_key: 'in_reply_to_id', class_name: 'Status', inverse_of: :replies, optional: true
  belongs_to :reblog, foreign_key: 'reblog_of_id', class_name: 'Status', inverse_of: :reblogs, optional: true
  belongs_to :quote, foreign_key: 'quote_of_id', class_name: 'Status', inverse_of: :quotes, optional: true

  has_many :favourites, inverse_of: :status, dependent: :destroy
  has_many :unfavourites, inverse_of: :status, dependent: :destroy
  has_many :status_bookmarks, inverse_of: :status, dependent: :destroy
  has_many :reblogs, foreign_key: 'reblog_of_id', class_name: 'Status', inverse_of: :reblog, dependent: :destroy
  has_many :quotes, foreign_key: 'quote_of_id', class_name: 'Status', inverse_of: :quote, dependent: :nullify
  has_many :replies, foreign_key: 'in_reply_to_id', class_name: 'Status', inverse_of: :thread
  has_many :mentions, dependent: :destroy, inverse_of: :status
  has_many :active_mentions, -> { active }, class_name: 'Mention', inverse_of: :status
  has_many :media_attachments, dependent: :nullify
  has_many :revisions, class_name: 'StatusRevision', dependent: :destroy

  has_and_belongs_to_many :tags
  has_and_belongs_to_many :preview_cards

  has_one :notification, as: :activity, dependent: :destroy
  has_one :status_stat, inverse_of: :status
  has_one :poll, inverse_of: :status, dependent: :destroy

  validates :uri, uniqueness: true, presence: true, unless: :local?
  validates :text, presence: true, unless: -> { with_media? || reblog? }
  validates_with StatusLengthValidator
  validates_with StatusLimitValidator
  validates :reblog, uniqueness: { scope: :account }, if: :reblog?
  validates :visibility, exclusion: { in: %w(limited) }, if: :reblog?

  accepts_nested_attributes_for :poll

  default_scope { recent }

  scope :recent, -> { reorder(created_at: :desc) }
  scope :oldest, -> { reorder(created_at: :asc) }
  scope :top, -> { select('statuses.*, case when status_stats.favourites_count is null then 0 else status_stats.favourites_count end as favcount').left_outer_joins(:status_stat).reorder('favcount desc, statuses.id asc') }
  scope :remote, -> { where(local: false).or(where.not(uri: nil)) }
  scope :local,  -> { where(local: true).or(where(uri: nil)) }

  scope :only_replies, -> { where('statuses.reply IS TRUE') }
  scope :without_replies, -> { where('statuses.reply IS FALSE') }
  scope :without_reblogs, -> { where('statuses.reblog_of_id IS NULL') }
  scope :with_public_visibility, -> { where(visibility: :public) }
  scope :tagged_with, ->(tag) { joins(:statuses_tags).where(statuses_tags: { tag_id: tag }) }
  scope :excluding_silenced_accounts, -> { left_outer_joins(:account).where(accounts: { silenced_at: nil }) }
  scope :including_silenced_accounts, -> { left_outer_joins(:account).where.not(accounts: { silenced_at: nil }) }
  scope :popular_accounts, -> { left_outer_joins(:account).where('accounts.is_verified=true OR accounts.is_pro=true AND accounts.locked=false') }
  scope :not_excluded_by_account, ->(account) { where.not(account_id: account.excluded_from_timeline_account_ids) }
  scope :not_domain_blocked_by_account, ->(account) { account.excluded_from_timeline_domains.blank? ? left_outer_joins(:account) : left_outer_joins(:account).where('accounts.domain IS NULL OR accounts.domain NOT IN (?)', account.excluded_from_timeline_domains) }
  scope :tagged_with_all, ->(tags) {
    Array(tags).map(&:id).map(&:to_i).reduce(self) do |result, id|
      result.joins("INNER JOIN statuses_tags t#{id} ON t#{id}.status_id = statuses.id AND t#{id}.tag_id = #{id}")
    end
  }
  scope :tagged_with_none, ->(tags) {
    Array(tags).map(&:id).map(&:to_i).reduce(self) do |result, id|
      result.joins("LEFT OUTER JOIN statuses_tags t#{id} ON t#{id}.status_id = statuses.id AND t#{id}.tag_id = #{id}")
            .where("t#{id}.tag_id IS NULL")
    end
  }

  cache_associated :application,
                   :media_attachments,
                   :conversation,
                   :status_stat,
                   :tags,
                   :preview_cards,
                   :preloadable_poll,
                   account: :account_stat,
                   active_mentions: { account: :account_stat },
                   group: :group_categories,
                   reblog: [
                     :application,
                     :tags,
                     :preview_cards,
                     :media_attachments,
                     :conversation,
                     :status_stat,
                     :preloadable_poll,
                     account: :account_stat,
                     active_mentions: { account: :account_stat },
                   ],
                   thread: { account: :account_stat }

  delegate :domain, to: :account, prefix: true

  def searchable_by(preloaded = nil)
    ids = [account_id]

    if preloaded.nil?
      ids += mentions.pluck(:account_id)
      ids += favourites.pluck(:account_id)
      ids += reblogs.pluck(:account_id)
    else
      ids += preloaded.mentions[id] || []
      ids += preloaded.favourites[id] || []
      ids += preloaded.reblogs[id] || []
    end

    ids.uniq
  end

  def reply?
    !in_reply_to_id.nil? || attributes['reply']
  end

  def local?
    attributes['local'] || uri.nil?
  end

  def reblog?
    !reblog_of_id.nil?
  end

  def quote?
    !quote_of_id.nil?
  end

  def verb
    if destroyed?
      :delete
    else
      reblog? ? :share : :post
    end
  end

  def object_type
    reply? ? :comment : :note
  end

  def proper
    reblog? ? reblog : self
  end

  def content
    proper.text
  end

  def target
    reblog
  end

  def preview_card
    preview_cards.first
  end

  def title
    if destroyed?
      "#{account.acct} deleted status"
    else
      reblog? ? "#{account.acct} shared a status by #{reblog.account.acct}" : "New status by #{account.acct}"
    end
  end

  def hidden?
    private_visibility? || private_group_visibility? || limited_visibility?
  end

  def distributable?
    public_visibility? || unlisted_visibility?
  end

  def with_media?
    media_attachments.any?
  end

  def non_sensitive_with_media?
    !sensitive? && with_media?
  end

  def emojis
    return @emojis if defined?(@emojis)

    fields  = [spoiler_text, text]
    fields += preloadable_poll.options unless preloadable_poll.nil?

    @emojis = CustomEmoji.from_text(fields.join(' '))
  end

  def mark_for_mass_destruction!
    @marked_for_mass_destruction = true
  end

  def marked_for_mass_destruction?
    @marked_for_mass_destruction
  end

  def direct_replies_count
    replies.count
  end

  def replies_count
    return(0) unless persisted?
    
    @replies_count ||= Rails.cache.fetch("replies_count:#{id}", expires_in: 1.minutes) do    
      Status.count_by_sql([<<-SQL.squish, id: id])
        with recursive comment_counter AS(
          select id
          from statuses
          where in_reply_to_id = :id
        
          union
        
          select s.id
          from statuses s
          join comment_counter c on s.in_reply_to_id = c.id
        ) select count(*) from comment_counter;
      SQL
    end
  end

  def reblogs_count
    status_stat&.reblogs_count || 0
  end

  def favourites_count
    status_stat&.favourites_count || 0
  end

  def increment_count!(key)
    update_status_stat!(key => public_send(key) + 1)
  end

  def decrement_count!(key)
    update_status_stat!(key => [public_send(key) - 1, 0].max)
  end

  after_create_commit  :increment_counter_caches
  after_destroy_commit :decrement_counter_caches

  after_create_commit :store_uri, if: :local?
  after_create_commit :update_statistics, if: :local?

  around_create GabSocial::Snowflake::Callbacks

  before_validation :prepare_contents, if: :local?
  before_validation :set_reblog
  before_validation :set_visibility
  before_validation :set_conversation
  before_validation :set_has_quote
  before_validation :set_group_id
  before_validation :set_local

  after_create :set_poll_id

  class << self
    def selectable_visibilities
      visibilities.keys - %w(limited private_group)
    end

    def in_chosen_languages(account)
      where(language: nil).or where(language: account.chosen_languages)
    end

    def as_home_timeline(account)
      query = where('created_at > ?', 3.days.ago)
      query.where(account: [account] + account.following).without_replies
    end

    def as_group_timeline(group)
      query = where('created_at > ?', 10.days.ago)
      query.where(group: group).without_replies
    end

    def as_group_collection_timeline(groupIds)
      where(group: groupIds, reply: false)
    end

    def as_pro_timeline(account = nil)
      query = timeline_scope.without_replies.popular_accounts.where('statuses.updated_at > ?', 1.hours.ago)
      apply_timeline_filters(query, account)
    end

    def as_tag_timeline(tag, account = nil)
      query = timeline_scope.tagged_with(tag).without_replies

      apply_timeline_filters(query, account)
    end

    def as_outbox_timeline(account)
      where(account: account, visibility: :public)
    end

    def favourites_map(status_ids, account_id)
      Favourite.select('status_id').where(status_id: status_ids).where(account_id: account_id).each_with_object({}) { |f, h| h[f.status_id] = true }
    end

    def bookmarks_map(status_ids, account_id)
      StatusBookmark.select('status_id').where(status_id: status_ids).where(account_id: account_id).map { |f| [f.status_id, true] }.to_h
    end

    def reblogs_map(status_ids, account_id)
      select('reblog_of_id').where(reblog_of_id: status_ids).where(account_id: account_id).reorder(nil).each_with_object({}) { |s, h| h[s.reblog_of_id] = true }
    end

    def pins_map(status_ids, account_id)
      StatusPin.select('status_id').where(status_id: status_ids).where(account_id: account_id).each_with_object({}) { |p, h| h[p.status_id] = true }
    end

    def direct_replies_count_map(status_ids)
      unscoped.
        where(in_reply_to_id: status_ids).
        group(:in_reply_to_id).
        count
    end

    def group_pins_map(status_ids, group_id = nil)
      unless group_id.nil?
        GroupPinnedStatus.select('status_id').where(status_id: status_ids).where(group_id: group_id).each_with_object({}) { |p, h| h[p.status_id] = true }
      end
    end

    def reload_stale_associations!(cached_items)
      account_ids = []

      cached_items.each do |item|
        account_ids << item.account_id
        account_ids << item.reblog.account_id if item.reblog?
      end

      account_ids.uniq!

      return if account_ids.empty?

      accounts = Account.where(id: account_ids).includes(:account_stat, :user).each_with_object({}) { |a, h| h[a.id] = a }

      cached_items.each do |item|
        item.account = accounts[item.account_id]
        item.reblog.account = accounts[item.reblog.account_id] if item.reblog?
      end
    end

    def permitted_for(target_account, account)
      visibility = [:public, :unlisted]

      if account.nil?
        where(visibility: visibility)
      elsif target_account.blocking?(account) # get rid of blocked peeps
        none
      elsif account.id == target_account.id # author can see own stuff
        all
      else
        # followers can see followers-only stuff, but also things they are mentioned in.
        # non-followers can see everything that isn't private/direct, but can see stuff they are mentioned in.
        visibility.push(:private) if account.following?(target_account)

        scope = left_outer_joins(:reblog)

        scope.where(visibility: visibility)
             .or(scope.where(id: account.mentions.select(:status_id)))
             .merge(scope.where(reblog_of_id: nil).or(scope.where.not(reblogs_statuses: { account_id: account.excluded_from_timeline_account_ids })))
      end
    end

    private

    def timeline_scope
      Status.local
        .with_public_visibility
        .without_reblogs
    end

    def apply_timeline_filters(query, account)
      if account.nil?
        filter_timeline_default(query)
      else
        filter_timeline_for_account(query, account)
      end
    end

    def filter_timeline_for_account(query, account)
      query = query.not_excluded_by_account(account)
      query = query.in_chosen_languages(account) if account.chosen_languages.present?
      query.merge(account_silencing_filter(account))
    end

    def filter_timeline_default(query)
      query.excluding_silenced_accounts
    end

    def account_silencing_filter(account)
      if account.silenced?
        including_myself = left_outer_joins(:account).where(account_id: account.id).references(:accounts)
        excluding_silenced_accounts.or(including_myself)
      else
        excluding_silenced_accounts
      end
    end
  end

  def resync_status_stat!
    return if marked_for_destruction? || destroyed?

    replies_count = replies.count if reply_countable?
    reblogs_count = reblogs.count if reblog_countable?

    atts = {
      replies_count: replies_count,
      reblogs_count: reblogs_count,
    }.compact

    update_status_stat!(atts) if atts.present?
  end

  private

  def update_status_stat!(attrs)
    return if marked_for_destruction? || destroyed?

    record = status_stat || build_status_stat
    record.update(attrs)
  end

  def store_uri
    update_column(:uri, "/#{self.account.username}/posts/#{self.id}") if uri.nil?
  end

  def prepare_contents
    text&.strip!
    spoiler_text&.strip!
  end

  def set_reblog
    self.reblog = reblog.reblog if reblog? && reblog.reblog?
  end

  def set_poll_id
    update_column(:poll_id, poll.id) unless poll.nil?
  end

  def set_visibility
    self.visibility = reblog.visibility if reblog? && visibility.nil?
    self.visibility = (account.locked? ? :private : :public) if visibility.nil?
    self.sensitive  = false if sensitive.nil?
  end

  def set_group_id
    self.group_id = thread.group_id if thread&.group_id?

    if reply? && !thread.nil?
      replied_status = Status.find(in_reply_to_id)
      self.group_id = replied_status.group_id
    end
  end

  def set_conversation
    self.thread = thread.reblog if thread&.reblog?

    self.reply = !(in_reply_to_id.nil? && thread.nil?) unless reply

    if reply? && !thread.nil?
      self.in_reply_to_account_id = carried_over_reply_to_account_id
      self.conversation_id        = thread.conversation_id if conversation_id.nil?
    elsif conversation_id.nil?
      self.conversation = Conversation.new
    end
  end

  def set_has_quote
    self.has_quote = !quote_of_id.nil?
  end

  def carried_over_reply_to_account_id
    if thread.account_id == account_id && thread.reply?
      thread.in_reply_to_account_id
    else
      thread.account_id
    end
  end

  def set_local
    self.local = account.local?
  end

  def update_statistics
    return unless public_visibility? || unlisted_visibility?
    ActivityTracker.increment('activity:statuses:local')
  end

  def increment_counter_caches
    account&.increment_count!(:statuses_count)
    reblog&.increment_count!(:reblogs_count) if reblog? && reblog_countable?
    thread&.increment_count!(:replies_count) if in_reply_to_id.present? && reply_countable?
  end

  def decrement_counter_caches
    return if marked_for_mass_destruction?

    account&.decrement_count!(:statuses_count)
    reblog&.decrement_count!(:reblogs_count) if reblog? && reblog_countable?
    thread&.decrement_count!(:replies_count) if in_reply_to_id.present? && reply_countable?
  end

  def reblog_countable?
    public_visibility? || unlisted_visibility?
  end

  def reply_countable?
    public_visibility? || unlisted_visibility? || private_group_visibility?
  end

  def unlink_from_conversations
    # return unless direct_visibility?

    # mentioned_accounts = mentions.includes(:account).map(&:account)
    # inbox_owners       = mentioned_accounts.select(&:local?) + (account.local? ? [account] : [])

    # inbox_owners.each do |inbox_owner|
    #   AccountConversation.remove_status(inbox_owner, self)
    # end
  end

end
