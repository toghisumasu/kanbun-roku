# 会話ログの原本。追記のみで、更新・削除はしない。
# DB側のトリガーでも UPDATE / DELETE / TRUNCATE を拒否している。
class Message < ApplicationRecord
  has_many :diary_links, dependent: :restrict_with_exception
  has_many :diary_entries, through: :diary_links
  has_many :annotations, as: :annotatable, dependent: :restrict_with_exception

  validates :source, :external_id, :session_id, :role, :occurred_at, presence: true
  validates :body, exclusion: { in: [ nil ] } # 本文が空の発言（ツール使用だけなど）も原本として残す
  validates :external_id, uniqueness: { scope: :source }

  before_destroy { raise ActiveRecord::ReadOnlyRecord, "messages is append-only" }

  scope :on_date, ->(date) { where(occurred_at: date.in_time_zone.all_day).order(:occurred_at, :id) }

  def readonly?
    persisted? || super
  end
end
