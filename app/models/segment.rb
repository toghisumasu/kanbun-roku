# 会話の区切り。messages からの派生情報で、いつでも作り直せる。
class Segment < ApplicationRecord
  belongs_to :first_message, class_name: "Message"
  belongs_to :last_message, class_name: "Message"
  belongs_to :continued_from, class_name: "Segment", optional: true

  # 閉じた区切りは更新しない。日記は閉じた区切りからだけ作る。
  scope :open_ended, -> { where(end_reason: "open") }
  scope :closed, -> { where.not(end_reason: "open") }

  validates :session_id, :segment_date, :started_at, :ended_at, presence: true
  validates :start_reason, inclusion: { in: ConversationSegmenter::START_REASONS }
  validates :end_reason, inclusion: { in: ConversationSegmenter::END_REASONS }
end
