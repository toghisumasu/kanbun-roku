# 原本から生成する派生物。1つの座（segment）に1件。同じ座のものは作り直すときも同じ行を使い、
# 本文とリンクだけを入れ替える（この行に付けた注釈を残すため）。
# ダイアリーは closed の座にだけ作る（open の座は SegmentRebuilder が作り直すため）。
class DiaryEntry < ApplicationRecord
  belongs_to :segment
  has_many :diary_links, dependent: :delete_all
  has_many :messages, -> { order(:occurred_at, :id) }, through: :diary_links
  has_many :annotations, as: :annotatable, dependent: :restrict_with_exception

  validates :entry_date, presence: true
  validates :segment_id, uniqueness: true
end
