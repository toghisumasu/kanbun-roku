# 原本から生成する派生物。同じ日付のものは作り直すときも同じ行を使い、
# 本文とリンクだけを入れ替える（この行に付けた注釈を残すため）。
class DiaryEntry < ApplicationRecord
  has_many :diary_links, dependent: :delete_all
  has_many :messages, -> { order(:occurred_at, :id) }, through: :diary_links
  has_many :annotations, as: :annotatable, dependent: :restrict_with_exception

  validates :entry_date, presence: true, uniqueness: true
end
