# 座の塊ごとの A の呼び出しの記録（生の出力・所要時間・トークン数）。派生物で、作り直してよい。
class DiaryChunk < ApplicationRecord
  STATUSES = %w[ pending succeeded failed ].freeze

  belongs_to :segment

  validates :chunk_index, :input_digest, :model, :prompt_version, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :succeeded, -> { where(status: "succeeded") }
  scope :failed, -> { where(status: "failed") }
end
