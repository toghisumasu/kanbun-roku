# 後日の考察を足す層。原本には触れない。
class Annotation < ApplicationRecord
  ANNOTATABLE_TYPES = %w[Message DiaryEntry].freeze

  belongs_to :annotatable, polymorphic: true

  validates :body, presence: true
  validates :annotatable_type, inclusion: { in: ANNOTATABLE_TYPES }
end
