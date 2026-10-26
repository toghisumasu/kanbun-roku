class DiaryLink < ApplicationRecord
  belongs_to :diary_entry
  belongs_to :message

  validates :message_id, uniqueness: { scope: :diary_entry_id }
end
