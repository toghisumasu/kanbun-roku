# 会話の区切り。messages からの派生情報で、いつでも作り直せる。
class Segment < ApplicationRecord
  belongs_to :first_message, class_name: "Message"
  belongs_to :last_message, class_name: "Message"
  belongs_to :continued_from, class_name: "Segment", optional: true
  # ダイアリーは closed の座にだけ作る。open の座は SegmentRebuilder が delete_all で作り直す（コールバックなし）ので、
  # ダイアリーのある座を消そうとすると、DBの外部キー制約で止まる。
  has_one :diary_entry, dependent: :restrict_with_exception
  has_many :diary_chunks, dependent: :restrict_with_exception

  # 閉じた区切りは更新しない。日記は閉じた区切りからだけ作る。
  scope :open_ended, -> { where(end_reason: "open") }
  scope :closed, -> { where.not(end_reason: "open") }

  validates :session_id, :segment_date, :started_at, :ended_at, presence: true
  validates :start_reason, inclusion: { in: ConversationSegmenter::START_REASONS }
  validates :end_reason, inclusion: { in: ConversationSegmenter::END_REASONS }
end
