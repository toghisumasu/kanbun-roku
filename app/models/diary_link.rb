# ダイアリーから原本の発言へのリンク。
# link_kind: source = 引用から特定した人間の発言 / preceding_assistant_candidate = 直前の assistant 発言（候補。断定しない）。
# item_key = どの項目のリンクか（例「決定:2」）。NULL はダイアリー全体へのリンク。
class DiaryLink < ApplicationRecord
  LINK_KINDS = %w[ source preceding_assistant_candidate ].freeze

  belongs_to :diary_entry
  belongs_to :message

  validates :link_kind, inclusion: { in: LINK_KINDS }
  validates :message_id, uniqueness: { scope: %i[ diary_entry_id item_key link_kind ] }
end
