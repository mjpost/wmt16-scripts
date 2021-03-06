#!/bin/bash

#$ -cwd -S /bin/bash -V 
#$ -j y -o validate/validate.log 
#$ -l h_rt=24:00:00,num_proc=1

if [[ -z $1 ]]; then
    echo "Usage: validate-qsub.sh MODEL"
    exit 1
fi

prefix=$1

. ./params.txt

# Load the GPU-specific commands if necessary
if [[ $device = "gpu" ]]; then
  echo "Loading GPU"
  . $TRAIN/gpu.sh
fi

[[ ! -d validate ]] && mkdir validate

dev=data/validate.bpe.$SRC
ref=data/validate.tc.$TRG
modelname=$(basename $prefix .npz)
out=validate/validate.$modelname.output

if [[ $FACTORS -gt 1 ]]; then
    dev=data/validate.factors.$SRC
fi

# quit if it's already been done
if [[ -s $out ]]; then
    wanted=$(cat $ref | wc -l)
    found=$(cat $out | wc -l)
    if [[ $wanted -eq $found ]]; then
        exit
    fi
fi

hostname=$(hostname)
devno=$($TRAIN/free-gpu)
echo "Using device $devno on $hostname" 
env | grep SGE_HGR_gpu
nvidia-smi

# decode
if [[ -z $MARIAN ]] || [[ ! -x $MARIAN/build/amun ]]; then
    THEANO_FLAGS=mode=FAST_RUN,floatX=float32,device=$device$devno,on_unused_input=warn python $nematus/nematus/translate.py \
        -m $prefix \
        -i $dev \
        -o $out \
        -k 12 -n -p 1
else

    VOCAB=../data/train.bpe.$SRC.json
    if [[ $FACTORS -gt 1 ]]; then
        for num in $(seq 1 $FACTORS); do
            if [[ $num -eq $FACTORS ]]; then
                break
            fi
            VOCAB+=", data/train.factors.$num.$SRC.json"
        done

        VOCAB="[$VOCAB]"
    fi
cat > validate/config.$modelname.yml <<EOF
# Paths are relative to config file location
relative-paths: yes

# performance settings
beam-size: 12
normalize: yes

# scorer configuration
scorers:
  F0:
    path: ../$prefix
    type: Nematus

# scorer weights
weights:
  F0: 1.0

# vocabularies
source-vocab: $VOCAB
target-vocab: ../data/train.bpe.$TRG.json

# don't apply BPE because that has already been done
#bpe: ../model/$SRC$TRG.bpe
debpe: false
EOF

cmd="$MARIAN/build/amun -c validate/config.$modelname.yml -d 0 -i $dev"
echo "Running [on device $devno] $cmd > $out"
CUDA_VISIBLE_DEVICES=$devno $cmd > $out
fi

lineswanted=$(cat $dev | wc -l)
linesfound=$(cat $out | wc -l)
if [[ $lineswanted -ne $linesfound ]]; then
  echo "* ERROR: output file $out has only $linesfound lines (needed $lineswanted)"
  echo "* something must have gone wrong, quitting"
  exit
fi

$TRAIN/postprocess-dev.sh < $out > $out.postprocessed

## get BLEU
BEST=`cat model/best_bleu.txt 2> /dev/null || echo 0`
bleu_output=$($TRAIN/moses-scripts/generic/multi-bleu.perl -lc $ref < $out.postprocessed)
echo -e "$prefix\t$bleu_output" >> model/bleu_scores.txt
BLEU=`echo $bleu_output | cut -f 3 -d ' ' | cut -f 1 -d ','`
BETTER=`echo "$BLEU > $BEST" | bc`

echo "BLEU = $BLEU"

# save model with highest BLEU
if [ "$BETTER" = "1" ]; then
  echo "new best; saving"
  echo $BLEU > model/best_bleu.txt
  ln -sf $(basename $prefix) model/best_model.npz
fi
