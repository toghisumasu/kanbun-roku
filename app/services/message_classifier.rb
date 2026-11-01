# 発言の分類。DBには触れない純粋な関数。判定は role / body / raw だけで行い、結果は保存しない。
#
# - paste_text:  user の発言で、端末出力などの貼り付けと見られるもの
#                （シェルのプロンプト行を含む複数行、または長い複数行）
# - paste_media: user の発言で、本文が空で、raw に image / document があるもの
# - utterance:   それ以外（assistant の発言はすべてここ）
#
# media の手がかりは claude.ai エクスポートの raw から取る。content のブロック（image / document）のほか、
# files（拡張子で image / それ以外を分ける。拡張子なしは document）と attachments（document）も見る。
# content のブロックは files の一部にしか付いていないので、files も見ないと画像の多くを取りこぼす。
module MessageClassifier
  CLASSES = %i[ paste_text paste_media utterance ].freeze

  # 長い複数行: 空でない行数と文字数の両方がこの値以上。
  PASTE_MIN_LINES = 20
  PASTE_MIN_CHARS = 1_200
  # シェルのプロンプト行を含む場合は、空でない行数がこの値以上で貼り付けとみなす。
  SHELL_PROMPT_MIN_LINES = 3
  # 行頭が「user@host dir % cmd」「$ cmd」「% cmd」「❯ cmd」「➜ dir」の形の行。venv の「(env) 」は許す。
  SHELL_PROMPT = /\A(?:\(\S+\)\s*)?(?:\S+@\S+[^\n]{0,80}?[%$#]\s+\S|[%$]\s+\S|[❯➜]\s+\S)/

  # Claude 文の貼り付けを置き換えたあとの残りに、端末出力の行があるかの判定に使う（1行ずつ）。
  # プロンプトだけの行（コマンドなし）、「~ $」、Password:、進捗の「NN%」も端末出力とみなす。
  PROMPT_ONLY = /\A(?:\(\S+\)\s*)?\S+@\S+[^\n]{0,80}?[%$#]\s*\z/
  TILDE_PROMPT = /\A(?:\(\S+\)\s*)?\S*~\S*\s+[$%#](?:\s|\z)/
  PASSWORD_PROMPT = /\APassword:/i
  # 行頭が「NN%」、または「NN%」のあとに進捗バーの記号が続く行。文の途中や文末の「50%」は拾わない。
  PROGRESS = /\A\s*\d{1,3}%|\d{1,3}%\s*[|\[█▏▎▍▌▋▊▉]/

  IMAGE_EXTENSIONS = %w[ png jpg jpeg gif webp heic heif bmp ].freeze

  # raw の手がかりから見た添付の種類の集合（:image / :document）。
  def self.media_kinds(raw)
    raw = raw || {}
    kinds = []
    Array(raw["content"]).each do |block|
      type = block.is_a?(Hash) ? block["type"] : nil
      kinds << :image if type == "image"
      kinds << :document if type == "document"
    end
    Array(raw["files"]).each do |file|
      name = file.is_a?(Hash) ? file["file_name"].to_s : ""
      ext = name.include?(".") ? name.split(".").last.downcase : ""
      kinds << (IMAGE_EXTENSIONS.include?(ext) ? :image : :document)
    end
    kinds << :document if Array(raw["attachments"]).any?
    kinds.uniq
  end

  def self.shell_output?(body)
    lines = body.lines.reject { |l| l.strip.empty? }
    lines.size >= SHELL_PROMPT_MIN_LINES && lines.any? { |l| l.lstrip.match?(SHELL_PROMPT) }
  end

  def self.prompt_line?(line)
    line = line.strip
    [ SHELL_PROMPT, PROMPT_ONLY, TILDE_PROMPT, PASSWORD_PROMPT, PROGRESS ].any? { |re| line.match?(re) }
  end

  # 行数に下限を設けず、端末出力らしい行が1行でもあるか。
  def self.prompt_lines?(text)
    text.to_s.each_line.any? { |line| prompt_line?(line) }
  end

  def self.long_multiline?(body)
    body.size >= PASTE_MIN_CHARS && body.lines.count { |l| !l.strip.empty? } >= PASTE_MIN_LINES
  end

  def self.classify(role:, body:, raw: nil)
    return :utterance unless role == "user"

    body = body.to_s
    return (media_kinds(raw).empty? ? :utterance : :paste_media) if body.strip.empty?
    return :paste_text if long_multiline?(body) || shell_output?(body)

    :utterance
  end

  # 本文が空の発言の内訳用。image / document / both / neither。
  def self.media_label(raw)
    kinds = media_kinds(raw)
    return :neither if kinds.empty?
    return :both if kinds.size == 2

    kinds.first
  end
end
