# 区切りの型。貼り付け（paste_text / paste_media）の比率で work / talk に分ける。DBには触れない。
# 比率は user の発言の数に対する貼り付けの数。assistant の発言は数えない。
module SegmentTyper
  # この比率以上なら work、未満なら talk。
  WORK_PASTE_RATIO = 0.3

  # classes: 区切りの発言の分類（MessageClassifier.classify の結果）と role の組の列ではなく、
  # user の発言の分類だけを渡す。user の発言がなければ talk。
  def self.paste_ratio(user_classes)
    return 0.0 if user_classes.empty?

    user_classes.count { |c| c != :utterance }.fdiv(user_classes.size)
  end

  def self.call(user_classes, threshold: WORK_PASTE_RATIO)
    paste_ratio(user_classes) >= threshold ? :work : :talk
  end
end
