#!/usr/bin/env bash

set -eou pipefail

nj=15
stage=-1
stop_stage=100

# We assume dl_dir (download dir) contains the following
# directories and files. If not, they will be downloaded
# by this script automatically.
#
#  - $dl_dir/LibriSpeech
#      You can find BOOKS.TXT, test-clean, train-clean-360, etc, inside it.
#      You can download them from https://www.openslr.org/12
#
#  - $dl_dir/lm
#      This directory contains the following files downloaded from
#       http://www.openslr.org/resources/11
#
#        - 3-gram.pruned.1e-7.arpa.gz
#        - 3-gram.pruned.1e-7.arpa
#        - 4-gram.arpa.gz
#        - 4-gram.arpa
#        - librispeech-vocab.txt
#        - librispeech-lexicon.txt
#
#  - $dl_dir/musan
#      This directory contains the following directories downloaded from
#       http://www.openslr.org/17/
#
#     - music
#     - noise
#     - speech
dl_dir=$PWD/download
mkdir -p $dl_dir

. shared/parse_options.sh || exit 1

# vocab size for sentence piece models.
# It will generate data/lang_bpe_xxx,
# data/lang_bpe_yyy if the array contains xxx, yyy
vocab_sizes=(
  500
)

# All files generated by this script are saved in "data".
# You can safely remove "data" and rerun this script to regenerate it.
mkdir -p data

log() {
  # This function is from espnet
  local fname=${BASH_SOURCE[1]##*/}
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') (${fname}:${BASH_LINENO[0]}:${FUNCNAME[1]}) $*"
}

log "dl_dir: $dl_dir"

if [ $stage -le 0 ] && [ $stop_stage -ge 0 ]; then
  log "Stage 0: Download data"

  # If you have pre-downloaded it to /path/to/fisher and /path/to/swbd,
  # you can create a symlink
  #
  #   ln -sfv /path/to/fisher $dl_dir/fisher
  #

  # TODO: remove
  LDC_ROOT=/fsx/resources/LDC
  for pkg in LDC2004S13 LDC2004T19 LDC2005S13 LDC2005T19 LDC97S62; do
    ln -sfv $LDC_ROOT/$pkg $dl_dir/
  done

  # If you have pre-downloaded it to /path/to/musan,
  # you can create a symlink
  #
  #   ln -sfv /path/to/musan $dl_dir/
  #
  if [ ! -d $dl_dir/musan ]; then
    lhotse download musan $dl_dir
  fi
fi

if [ $stage -le 1 ] && [ $stop_stage -ge 1 ]; then
  log "Stage 1: Prepare Fisher manifests"
  # We assume that you have downloaded the LibriSpeech corpus
  # to $dl_dir/LibriSpeech
  mkdir -p data/manifests/fisher
  lhotse prepare fisher-english --absolute-paths 1 $dl_dir data/manifests/fisher
fi

if [ $stage -le 2 ] && [ $stop_stage -ge 2 ]; then
  log "Stage 2: Prepare SWBD manifests"
  # We assume that you have downloaded the LibriSpeech corpus
  # to $dl_dir/LibriSpeech
  mkdir -p data/manifests/swbd
  lhotse prepare switchboard --absolute-paths 1 --omit-silence $dl_dir/LDC97S62 data/manifests/swbd
fi

if [ $stage -le 3 ] && [ $stop_stage -ge 3 ]; then
  log "Stage 3: Prepare musan manifest"
  # We assume that you have downloaded the musan corpus
  # to data/musan
  mkdir -p data/manifests
  lhotse prepare musan $dl_dir/musan data/manifests
fi

if [ $stage -le 4 ] && [ $stop_stage -ge 4 ]; then
  log "Stage 4: Combine Fisher + SBWD manifests"

  set -x

  # Combine Fisher and SWBD recordings and supervisions
  lhotse combine \
   data/manifests/fisher/recordings.jsonl.gz \
   data/manifests/swbd/swbd_recordings.jsonl \
   data/manifests/fisher-swbd_recordings.jsonl.gz
  lhotse combine \
   data/manifests/fisher/supervisions.jsonl.gz \
   data/manifests/swbd/swbd_supervisions.jsonl \
   data/manifests/fisher-swbd_supervisions.jsonl.gz

  # Normalize text and remove supervisions that are not useful / hard to handle.
  python local/normalize_and_filter_supervisions.py \
    data/manifests/fisher-swbd_supervisions.jsonl.gz \
    data/manifests/fisher-swbd_supervisions_norm.jsonl.gz \
  
  # Create cuts that span whole recording sessions.
  lhotse cut simple \
    -r data/manifests/fisher-swbd_recordings.jsonl.gz \
    -s data/manifests/fisher-swbd_supervisions_norm.jsonl.gz \
    data/manifests/fisher-swbd_cuts_unshuf.jsonl.gz
  
  # Shuffle the cuts (pure bash pipes are fast).
  # We could technically skip this step but this helps ensure
  # SWBD is not only seen towards the end of training.
  gunzip -c data/manifests/fisher-swbd_cuts_unshuf.jsonl.gz \
    | shuf \
    | gzip -c \
    > data/manifests/fisher-swbd_cuts.jsonl.gz

  # Create train/dev split -- 20 sessions for dev is about ~2h, should be good.
  num_cuts="$(gunzip -c data/manifests/fisher-swbd_cuts.jsonl.gz | wc -l)"
  num_dev_sessions=20
  lhotse subset --first $num_dev_sessions \
    data/manifests/fisher-swbd_cuts.jsonl.gz \
    data/manifests/dev_fisher-swbd_cuts.jsonl.gz
  lhotse subset --last $((num_cuts-num_dev_sessions)) \
    data/manifests/fisher-swbd_cuts.jsonl.gz \
    data/manifests/train_fisher-swbd_cuts.jsonl.gz

  # Finally, split the full-session cuts into one cut per supervision segment.
  # In case any segments are overlapping we would discard the info about overlaps.
  # (overlaps are unlikely for this dataset because each cut sees only one channel).
  lhotse cut trim-to-supervisions \
    --discard-overlapping \
    data/manifests/train_fisher-swbd_cuts.jsonl.gz \
    data/manifests/train_utterances_fisher-swbd_cuts.jsonl.gz
  lhotse cut trim-to-supervisions \
    --discard-overlapping \
    data/manifests/dev_fisher-swbd_cuts.jsonl.gz \
    data/manifests/dev_utterances_fisher-swbd_cuts.jsonl.gz

  set +x
fi

if [ $stage -le 6 ] && [ $stop_stage -ge 6 ]; then
  log "Stage 6: Dump transcripts for LM training"
  mkdir -p data/lm
  gunzip -c data/manifests/fisher-swbd_supervisions_norm.jsonl.gz \
    | jq '.text' \
    | sed 's:"::g' \
    > data/lm/transcript_words.txt
fi

if [ $stage -le 7 ] && [ $stop_stage -ge 7 ]; then
  log "Stage 7: Prepare lexicon using g2p_en"
  lang_dir=data/lang_phone
  mkdir -p $lang_dir

  # Add special words to words.txt
  echo "<eps> 0" > $lang_dir/words.txt
  echo "!SIL 1" >> $lang_dir/words.txt
  echo "[UNK] 2" >> $lang_dir/words.txt

  # Add regular words to words.txt
  gunzip -c data/manifests/fisher-swbd_supervisions_norm.jsonl.gz \
    | jq '.text' \
    | sed 's:"::g' \
    | sed 's: :\n:g' \
    | sort \
    | uniq \
    | awk '{print $0,NR+2}' \
    >> $lang_dir/words.txt

  # Add remaining special word symbols expected by LM scripts.
  num_words=$(wc -l $lang_dir/words.txt)
  echo "<s> ${num_words}" >> $lang_dir/words.txt
  num_words=$(wc -l $lang_dir/words.txt)
  echo "</s> ${num_words}" >> $lang_dir/words.txt
  num_words=$(wc -l $lang_dir/words.txt)
  echo "#0 ${num_words}" >> $lang_dir/words.txt

  if [ ! -f $lang_dir/L_disambig.pt ]; then
    pip install g2p_en
    ./local/prepare_lang_g2pen.py --lang-dir $lang_dir
  fi
fi

if [ $stage -le 8 ] && [ $stop_stage -ge 8 ]; then
  log "Stage 8: Prepare BPE based lang"

  for vocab_size in ${vocab_sizes[@]}; do
    lang_dir=data/lang_bpe_${vocab_size}
    mkdir -p $lang_dir
    # We reuse words.txt from phone based lexicon
    # so that the two can share G.pt later.
    cp data/lang_phone/words.txt $lang_dir

    ./local/train_bpe_model.py \
      --lang-dir $lang_dir \
      --vocab-size $vocab_size \
      --transcript data/lm/transcript_words.txt

    if [ ! -f $lang_dir/L_disambig.pt ]; then
      ./local/prepare_lang_bpe.py --lang-dir $lang_dir
    fi
  done
fi

if [ $stage -le 9 ] && [ $stop_stage -ge 9 ]; then
  log "Stage 9: Train LM"
  lm_dir=data/lm

  if [ ! -f $lm_dir/G.arpa ]; then
    ./shared/make_kn_lm.py \
      -ngram-order 3 \
      -text $lm_dir/transcript_words.txt \
      -lm $lm_dir/G.arpa
  fi

  if [ ! -f $lm_dir/G_3_gram.fst.txt ]; then
    python3 -m kaldilm \
      --read-symbol-table="data/lang_phone/words.txt" \
      --disambig-symbol='#0' \
      --max-order=3 \
      $lm_dir/G.arpa > $lm_dir/G_3_gram.fst.txt
  fi
fi

if [ $stage -le 10 ] && [ $stop_stage -ge 10 ]; then
  log "Stage 10: Compile HLG"
  ./local/compile_hlg.py --lang-dir data/lang_phone

  for vocab_size in ${vocab_sizes[@]}; do
    lang_dir=data/lang_bpe_${vocab_size}
    ./local/compile_hlg.py --lang-dir $lang_dir
  done
fi
