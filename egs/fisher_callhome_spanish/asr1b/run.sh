#!/bin/bash

# Copyright 2019 Kyoto University (Hirofumi Inaguma)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch # chainer or pytorch
stage=0         # start from 0 if you need to start from data preparation
stop_stage=100
ngpu=1          # number of gpus ("0" uses cpu, otherwise use gpu)
debugmode=1
dumpdir=dump    # directory to dump full features
N=0             # number of minibatches to be used (mainly for debugging). "0" uses all minibatches.
verbose=0       # verbose option
resume=         # Resume the training from snapshot
seed=1          # seed to generate random number
# feature configuration
do_delta=false

preprocess_config=
train_config=conf/train.yaml
lm_config=conf/lm.yaml
decode_config=conf/decode.yaml

# rnnlm related
lm_resume=        # specify a snapshot file to resume LM training
lmtag=            # tag for managing LMs

# decoding parameter
recog_model=model.acc.best # set a model to be used for decoding: 'model.acc.best' or 'model.loss.best'

# model average realted (only for transformer)
n_average=5                  # the number of ASR models to be averaged
use_valbest_average=true     # if true, the validation `n_average`-best ASR models will be averaged.
                             # if false, the last `n_average` ASR models will be averaged.

# preprocessing related
case=lc.rm
# tc: truecase
# lc: lowercase
# lc.rm: lowercase with punctuation removal

# Set this to somewhere where you want to put your data, or where
# someone else has already put it.  You'll want to change this
# if you're not on the CLSP grid.
sfisher_speech=/export/corpora/LDC/LDC2010S01
sfisher_transcripts=/export/corpora/LDC/LDC2010T04
split=local/splits/split_fisher

callhome_speech=/export/corpora/LDC/LDC96S35
callhome_transcripts=/export/corpora/LDC/LDC96T17
split_callhome=local/splits/split_callhome

# bpemode (unigram or bpe)
nbpe=1000
bpemode=bpe
# NOTE: nbpe=48 means character-level ASR (lc.rm)

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

train_set=train_sp.es
train_set_prefix=train_sp
train_dev=train_dev.es
recog_set="fisher_dev.es fisher_dev2.es fisher_test.es callhome_devtest.es callhome_evltest.es"

if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    ### Task dependent. You have to make data the following preparation part by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 0: Data Preparation"
    local/fsp_data_prep.sh ${sfisher_speech} ${sfisher_transcripts}
    local/callhome_data_prep.sh ${callhome_speech} ${callhome_transcripts}

    # split data
    local/create_splits.sh ${split}
    local/callhome_create_splits.sh ${split_callhome}

    # concatenate multiple utterances
    local/normalize_trans.sh ${sfisher_transcripts} ${callhome_transcripts}
fi

feat_tr_dir=${dumpdir}/${train_set}/delta${do_delta}; mkdir -p ${feat_tr_dir}
feat_dt_dir=${dumpdir}/${train_dev}/delta${do_delta}; mkdir -p ${feat_dt_dir}
if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    ### Task dependent. You have to design training and dev sets by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 1: Feature Generation"
    fbankdir=fbank
    # Generate the fbank features; by default 80-dimensional fbanks with pitch on each frame
    for x in fisher_dev fisher_dev2 fisher_test callhome_devtest callhome_evltest; do
        # upsample audio from 8k to 16k to make a recipe consistent with others
        sed -i.bak -e "s/$/ sox -R -t wav - -t wav - rate 16000 dither | /" data/${x}/wav.scp

        steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
            data/${x} exp/make_fbank/${x} ${fbankdir}
    done

    # speed-perturbed. data/${train_set_ori} is the orignal and data/${train_set} is the augmented
    sed -i.bak -e "s/$/ sox -R -t wav - -t wav - rate 16000 dither | /" data/fisher_train/wav.scp
    utils/perturb_data_dir_speed.sh 0.9 data/fisher_train data/temp1
    utils/perturb_data_dir_speed.sh 1.0 data/fisher_train data/temp2
    utils/perturb_data_dir_speed.sh 1.1 data/fisher_train data/temp3
    utils/combine_data.sh --extra-files utt2uniq data/train_sp data/temp1 data/temp2 data/temp3
    rm -r data/temp1 data/temp2 data/temp3
    steps/make_fbank_pitch.sh --cmd "$train_cmd" --nj 32 --write_utt2num_frames true \
        data/train_sp exp/make_fbank/train_sp ${fbankdir}
    utils/fix_data_dir.sh data/train_sp
    utils/validate_data_dir.sh data/train_sp

    for lang in es en; do
        awk -v p="sp0.9-" '{printf("%s %s%s\n", $1, p, $1);}' data/fisher_train/utt2spk > data/train_sp/utt_map
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.tc.${lang} >data/train_sp/text.tc.${lang}
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.lc.${lang} >data/train_sp/text.lc.${lang}
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.lc.rm.${lang} >data/train_sp/text.lc.rm.${lang}
        awk -v p="sp1.0-" '{printf("%s %s%s\n", $1, p, $1);}' data/fisher_train/utt2spk > data/train_sp/utt_map
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.tc.${lang} >>data/train_sp/text.tc.${lang}
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.lc.${lang} >>data/train_sp/text.lc.${lang}
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.lc.rm.${lang} >>data/train_sp/text.lc.rm.${lang}
        awk -v p="sp1.1-" '{printf("%s %s%s\n", $1, p, $1);}' data/fisher_train/utt2spk > data/train_sp/utt_map
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.tc.${lang} >>data/train_sp/text.tc.${lang}
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.lc.${lang} >>data/train_sp/text.lc.${lang}
        utils/apply_map.pl -f 1 data/train_sp/utt_map <data/fisher_train/text.lc.rm.${lang} >>data/train_sp/text.lc.rm.${lang}
    done

    # Divide into source and target languages
    for x in ${train_set_prefix} fisher_dev fisher_dev2 fisher_test callhome_devtest callhome_evltest; do
        local/divide_lang.sh ${x}
    done

    for lang in es en; do
        if [ -d data/train_dev.${lang} ];then
            rm -rf data/train_dev.${lang}
        fi
        cp -rf data/fisher_dev.${lang} data/train_dev.${lang}
    done
    # NOTE: do not use callhome_train for the training set

    for x in ${train_set_prefix} train_dev; do
        # remove utt having more than 3000 frames
        # remove utt having more than 400 characters
        for lang in es en; do
            remove_longshortdata.sh --maxframes 3000 --maxchars 400 data/${x}.${lang} data/${x}.${lang}.tmp
        done

        # Match the number of utterances between source and target languages
        # extract commocn lines
        cut -f 1 -d " " data/${x}.es.tmp/text > data/${x}.en.tmp/reclist1
        cut -f 1 -d " " data/${x}.en.tmp/text > data/${x}.en.tmp/reclist2
        comm -12 data/${x}.en.tmp/reclist1 data/${x}.en.tmp/reclist2 > data/${x}.en.tmp/reclist

        for lang in es en; do
            reduce_data_dir.sh data/${x}.${lang}.tmp data/${x}.en.tmp/reclist data/${x}.${lang}
            utils/fix_data_dir.sh --utt_extra_files "text.tc text.lc text.lc.rm" data/${x}.${lang}
        done
        rm -rf data/${x}.*.tmp
    done

    # compute global CMVN
    compute-cmvn-stats scp:data/${train_set}/feats.scp data/${train_set}/cmvn.ark

    # dump features for training
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_tr_dir}/storage ]; then
      utils/create_split_dir.pl \
          /export/b{14,15,16,17}/${USER}/espnet-data/egs/fisher_callhome_spanish/asr1b/dump/${train_set}/delta${do_delta}/storage \
          ${feat_tr_dir}/storage
    fi
    if [[ $(hostname -f) == *.clsp.jhu.edu ]] && [ ! -d ${feat_dt_dir}/storage ]; then
      utils/create_split_dir.pl \
          /export/b{14,15,16,17}/${USER}/espnet-data/egs/fisher_callhome_spanish/asr1b/dump/${train_dev}/delta${do_delta}/storage \
          ${feat_dt_dir}/storage
    fi
    dump.sh --cmd "$train_cmd" --nj 80 --do_delta $do_delta \
        data/${train_set}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/${train_set} ${feat_tr_dir}
    dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
        data/${train_dev}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/${train_dev} ${feat_dt_dir}
    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}; mkdir -p ${feat_recog_dir}
        dump.sh --cmd "$train_cmd" --nj 32 --do_delta $do_delta \
            data/${rtask}/feats.scp data/${train_set}/cmvn.ark exp/dump_feats/recog/${rtask} \
            ${feat_recog_dir}
    done
fi

dict=data/lang_1spm/${train_set}_${bpemode}${nbpe}_units_${case}.txt
nlsyms=data/lang_1spm/${train_set}_non_lang_syms_${case}.txt
bpemodel=data/lang_1spm/${train_set}_${bpemode}${nbpe}_${case}
echo "dictionary: ${dict}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1spm/

    echo "make a non-linguistic symbol list for all languages"
    grep sp1.0 data/${train_set}/text.${case} | cut -f 2- -d' ' | grep -o -P '&[^;]*;'| sort | uniq > ${nlsyms}
    cat ${nlsyms}

    echo "make a dictionary"
    echo "<unk> 1" > ${dict} # <unk> must be 1, 0 will be used for "blank" in CTC
    offset=$(wc -l < ${dict})
    grep sp1.0 data/${train_set}/text.${case} | cut -f 2- -d' ' | grep -v -e '^\s*$' > data/lang_1spm/input.txt
    spm_train --user_defined_symbols="$(tr "\n" "," < ${nlsyms})" --input=data/lang_1spm/input.txt --vocab_size=${nbpe} --model_type=${bpemode} --model_prefix=${bpemodel} --input_sentence_size=100000000 --character_coverage=1.0
    spm_encode --model=${bpemodel}.model --output_format=piece < data/lang_1spm/input.txt | tr ' ' '\n' | sort | uniq | awk -v offset=${offset} '{print $0 " " NR+offset}' >> ${dict}
    wc -l ${dict}
    # NOTE: ASR vocab is created with a source language only

    echo "make json files"
    local/data2json.sh --nj 16 --feat ${feat_tr_dir}/feats.scp --text data/${train_set}/text.${case} --bpecode ${bpemodel}.model \
        data/${train_set} ${dict} > ${feat_tr_dir}/data_${bpemode}${nbpe}.${case}.json
    local/data2json.sh --feat ${feat_dt_dir}/feats.scp --text data/${train_dev}/text.${case} --bpecode ${bpemodel}.model \
        data/${train_dev} ${dict} > ${feat_dt_dir}/data_${bpemode}${nbpe}.${case}.json
    for rtask in ${recog_set}; do
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}
        local/data2json.sh --feat ${feat_recog_dir}/feats.scp --text data/${rtask}/text.${case} --bpecode ${bpemodel}.model \
            data/${rtask} ${dict} > ${feat_recog_dir}/data_${bpemode}${nbpe}.${case}.json
    done
fi

# You can skip this and remove --rnnlm option in the recognition (stage 3)
if [ -z ${lmtag} ]; then
    lmtag=$(basename ${lm_config%.*})_${case}
fi
lmexpname=${train_set}_${case}_rnnlm_${backend}_${lmtag}_${bpemode}${nbpe}
lmexpdir=exp/${lmexpname}
mkdir -p ${lmexpdir}

if [ ${stage} -le 3 ] && [ ${stop_stage} -ge 3 ]; then
    echo "stage 3: LM Preparation"
    lmdatadir=data/local/lm_${train_set}_${bpemode}${nbpe}
    mkdir -p ${lmdatadir}
    grep sp1.0 data/${train_set}/text.${case} | cut -f 2- -d " " | spm_encode --model=${bpemodel}.model --output_format=piece \
        > ${lmdatadir}/train_${case}.txt
    cut -f 2- -d " " data/${train_dev}/text.${case} | spm_encode --model=${bpemodel}.model --output_format=piece \
        > ${lmdatadir}/valid_${case}.txt
    ${cuda_cmd} --gpu ${ngpu} ${lmexpdir}/train.log \
        lm_train.py \
        --config ${lm_config} \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --verbose 1 \
        --outdir ${lmexpdir} \
        --tensorboard-dir tensorboard/${lmexpname} \
        --train-label ${lmdatadir}/train_${case}.txt \
        --valid-label ${lmdatadir}/valid_${case}.txt \
        --resume ${lm_resume} \
        --dict ${dict}
fi

if [ -z ${tag} ]; then
    expname=${train_set}_${case}_${backend}_$(basename ${train_config%.*})_${bpemode}${nbpe}
    if ${do_delta}; then
        expname=${expname}_delta
    fi
    if [ -n "${preprocess_config}" ]; then
        expname=${expname}_$(basename ${preprocess_config%.*})
    fi
else
    expname=${train_set}_${case}_${backend}_${tag}
fi
expdir=exp/${expname}
mkdir -p ${expdir}

if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo "stage 4: Network Training"

    ${cuda_cmd} --gpu ${ngpu} ${expdir}/train.log \
        asr_train.py \
        --config ${train_config} \
        --preprocess-conf ${preprocess_config} \
        --ngpu ${ngpu} \
        --backend ${backend} \
        --outdir ${expdir}/results \
        --tensorboard-dir tensorboard/${expname} \
        --debugmode ${debugmode} \
        --dict ${dict} \
        --debugdir ${expdir} \
        --minibatches ${N} \
        --seed ${seed} \
        --verbose ${verbose} \
        --resume ${resume} \
        --train-json ${feat_tr_dir}/data_${bpemode}${nbpe}.${case}.json \
        --valid-json ${feat_dt_dir}/data_${bpemode}${nbpe}.${case}.json
fi

if [ ${stage} -le 5 ] && [ ${stop_stage} -ge 5 ]; then
    echo "stage 5: Decoding"
    if [[ $(get_yaml.py ${train_config} model-module) = *transformer* ]]; then
        # Average ASR models
        if ${use_valbest_average}; then
            recog_model=model.val${n_average}.avg.best
            opt="--log ${expdir}/results/log"
        else
            recog_model=model.last${n_average}.avg.best
            opt="--log"
        fi
        average_checkpoints.py \
            ${opt} \
            --backend ${backend} \
            --snapshots ${expdir}/results/snapshot.ep.* \
            --out ${expdir}/results/${recog_model} \
            --num ${n_average}
    fi
    nj=4

    pids=() # initialize pids
    for rtask in ${recog_set}; do
    (
        decode_dir=decode_${rtask}_$(basename ${decode_config%.*})
        feat_recog_dir=${dumpdir}/${rtask}/delta${do_delta}

        # split data
        splitjson.py --parts ${nj} ${feat_recog_dir}/data_${bpemode}${nbpe}.${case}.json

        #### use CPU for decoding
        ngpu=0

        ${decode_cmd} JOB=1:${nj} ${expdir}/${decode_dir}/log/decode.JOB.log \
            asr_recog.py \
            --config ${decode_config} \
            --ngpu ${ngpu} \
            --backend ${backend} \
            --batchsize 0 \
            --recog-json ${feat_recog_dir}/split${nj}utt/data_${bpemode}${nbpe}.JOB.json \
            --result-label ${expdir}/${decode_dir}/data.JOB.json \
            --model ${expdir}/results/${recog_model} \
            --rnnlm ${lmexpdir}/rnnlm.model.best

        local/score_sclite.sh --case ${case} --bpe ${nbpe} --bpemodel ${bpemodel}.model --wer true \
            ${expdir}/${decode_dir} ${dict}
    ) &
    pids+=($!) # store background pids
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((++i)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished"
fi
