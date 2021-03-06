--[[

Dynamic (Fine Tuned Word Embeddings LookupTable) CMOT-based Siamese Network

When we fine-tune, we make a LookupTable, and set its value to a Word2Vec
dataset.  This is augmented with a '<PADDING>' feature which is forced to
zero, even during optimization.  By default this code will trim out words
from the vocab. that are unattested during training.  This keeps the model
compact, but it might not be what you want.  To avoid this, pass -keepunused

]]--
require 'rnn'
require 'nn'
require 'xlua'
require 'optim'
require 'utils'
require 'data'
require 'train'
require 'torchure'
--require 'PrintIt'
torch.setdefaulttensortype('torch.FloatTensor')

-----------------------------------------------------
-- Defaults if you dont specify args
-- Note that some arguments depend on which optim
-- is selected, and may be unused for others. Try to
-- provide reasonable args for any algorithm a user selects
-----------------------------------------------------
DEF_TSF = '/data/xdata/para/tw/train.txt'
DEF_VSF = '/data/xdata/para/tw/dev.txt'
DEF_ESF = '/data/xdata/para/tw/test.txt'
DEF_BATCHSZ = 20
DEF_OPTIM = 'adadelta'
DEF_ETA = 0.001
DEF_MOM = 0.0
DEF_DECAY = 1e-9
DEF_DROP = 0.5
DEF_MXLEN = 40
DEF_ESZ = 300
DEF_CMOTSZ = 100
DEF_HSZ = -1 -- No additional projection layer
DEF_EMBED = './data/GoogleNews-vectors-negative300.bin'
DEF_FILE_OUT = './siamese-fine.model'
DEF_FSZ = 5
DEF_PATIENCE = 10
DEF_EPOCHS = 25
DEF_PROC = 'gpu'
DEF_CACTIVE = 'relu'
DEF_HACTIVE = 'relu'
DEF_EMBUNIF = 0.25
DEF_SHOW = 20
DEF_OUT_OF_CORE = false
linear = nil

---------------------------------------------------------------------
-- Make a Softmax output CMOT with Dropout and a word2vec LookupTable
---------------------------------------------------------------------
function createDistanceModel(lookupTable, cmotsz, cactive, hsz, hactive, filtsz, gpu, pdrop)
    local dsz = lookupTable.dsz
    local seq = nn.Sequential()


    seq:add(lookupTable)
    seq:add(newConv1D(dsz, cmotsz, filtsz, gpu))
    seq:add(activationFor(cactive, gpu))
    seq:add(nn.Max(2))
    seq:add(nn.Dropout(pdrop))

    if hsz > 0 then
       seq:add(newLinear(cmotsz, hsz))
       seq:add(activationFor(hactive, gpu))
    end

    local par = nn.ParallelTable(1,1)
    
    par:add(seq)
    par:add(seq:clone('weight','bias', 'gradWeight','gradBias'))
    


    local siamese = nn.Sequential()
    siamese:add(par)
    siamese:add(nn.CosineDistance())
--    siamese:add(nn.PairwiseDistance(2))

    return gpu and siamese:cuda() or siamese
end

--------------------------
-- Command line handling
--------------------------
cmd = torch.CmdLine()
cmd:text('Parameters for Siamese Network')
cmd:text()
cmd:text('Options:')
cmd:option('-save', DEF_FILE_OUT, 'Save model to')
cmd:option('-embed', DEF_EMBED, 'Word2Vec embeddings')
cmd:option('-embunif', DEF_EMBUNIF, 'Word2Vec initialization for non-attested attributes')
cmd:option('-eta', DEF_ETA, 'Initial learning rate')
cmd:option('-show', DEF_SHOW, '# results to show in test')
cmd:option('-optim', DEF_OPTIM, 'Optimization method (sgd|adagrad|adam|adadelta)')
cmd:option('-decay', DEF_DECAY, 'Weight decay')
cmd:option('-dropout', DEF_DROP, 'Dropout prob')
cmd:option('-mom', DEF_MOM, 'Momentum for SGD')
cmd:option('-train', DEF_TSF, 'Training file')
cmd:option('-valid', DEF_VSF, 'Validation file (optional)')
cmd:option('-eval', DEF_ESF, 'Test file')
cmd:option('-epochs', DEF_EPOCHS, 'Number of epochs')
cmd:option('-proc', DEF_PROC, 'Backend (gpu|cpu)')
cmd:option('-batchsz', DEF_BATCHSZ, 'Batch size')
cmd:option('-mxlen', DEF_MXLEN, 'Max number of tokens to use')
cmd:option('-patience', DEF_PATIENCE, 'How many failures to improve until quitting')
cmd:option('-hsz', DEF_HSZ, 'Depth of additional hidden layer')
cmd:option('-cmotsz', DEF_CMOTSZ, 'Depth of convolutional/max-over-time output')
cmd:option('-cactive', DEF_CACTIVE, 'Activation function following conv')
cmd:option('-filtsz', DEF_FSZ, 'Convolution filter width')
cmd:option('-clean', false, 'Cleanup tokens')
cmd:option('-keepunused', false, 'Keep unattested words in Lookup Table')
cmd:option('-ooc', DEF_OUT_OF_CORE, 'Should data batches be file-backed?')

local opt = cmd:parse(arg)
----------------------------------------
-- Optimization
----------------------------------------
config, optmeth = optimMethod(opt)

----------------------------------------
-- Processing on GPU or CPU
----------------------------------------
opt.gpu = false
if opt.proc == 'gpu' then
   opt.gpu = true
   require 'cutorch'
   require 'cunn'
   require 'cudnn'
else
   opt.proc = 'cpu'
end

print('Processing on ' .. opt.proc)


------------------------------------------------------------------------
-- This option is to clip unattested features from the LookupTable, for
-- processing efficiency
-- Reading from eval is not really cheating here
-- We are just culling the set to let the LUT be more compact for tests
-- This data already existed in pre-training!  We are just being optimal
-- here to keep memory footprint small
------------------------------------------------------------------------
local vocab = nil

if opt.keepunused == false then
   vocab = buildVocab({opt.train, opt.eval, opt.valid}, opt.clean)
   print('Removing unattested words')

end

---------------------------------------
-- Minibatches
---------------------------------------
print('Using batch size ' .. opt.batchsz)

-----------------------------------------------
-- Load Word2Vec Model and provide a hook for 
-- zero-ing the weights after each iteration
-----------------------------------------------
w2v = Word2VecLookupTable(opt.embed, vocab, opt.embunif)
local rlut = revlut(w2v.vocab)

function afterhook() 
      w2v.weight[w2v.vocab["<PADDING>"]]:zero()
end
opt.afteroptim = afterhook

print('Loaded word embeddings')
print('Vocab size ' .. w2v.vsz)


---------------------------------------
-- Load Feature Vectors
---------------------------------------
local f2i = {}
ts = sentsToIndices(opt.train, w2v, opt)
print('Loaded training data')

print('Using provided validation data')
vs = sentsToIndices(opt.valid, w2v, opt)

es = sentsToIndices(opt.eval, w2v, opt)

print('Using ' .. ts:size() .. ' batches for training')
print('Using ' .. vs:size() .. ' batches for validation')
print('Using ' .. es:size() .. ' batches for test')

---------------------------------------
-- Build model and criterion
---------------------------------------
local crit = createDistanceCrit(opt.gpu)
local model = createDistanceModel(w2v, opt.cmotsz, opt.cactive, opt.hsz, opt.hactive, opt.filtsz, opt.gpu, opt.dropout)

local errmin = 1
local lastImproved = 0

for i=1,opt.epochs do
    print('Training epoch ' .. i)
    trainEpoch(crit, model, ts, optmeth, opt)
    local erate = test(crit, model, rlut, vs, opt)
    if erate < errmin then
       errmin = erate
       lastImproved = i
       print('Lowest error achieved yet -- writing model')
       saveModel(model, opt.save, opt.gpu)
    end
    if (i - lastImproved) > opt.patience then
       print('Stopping due to persistent failures to improve')
       break
    end
end


print('Lowest loss seen in validation: ' .. errmin)
print('=====================================================')

print('Evaluating best model on test data')
model = loadModel(opt.save, opt.gpu)
local errmin = test(crit, model, rlut, es, opt)
print('Test loss: ' .. errmin)
print('=====================================================')
