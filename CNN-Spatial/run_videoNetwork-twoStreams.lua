-- Activity-Recognition-with-CNN-and-RNN
-- https://github.com/chihyaoma/Activity-Recognition-with-CNN-and-RNN

-- Load all the videos & Generate a feature matrix for each video
-- Select all the videos which have the frame numbers at least "numFrameMin"
-- No need to specify the video number
-- Follow the split sets provided in the UCF-101 website
-- Generate the name list corresponding to each video as well
-- load ResNet model (We use Res-101 now)
-- Process images based on the ResNet sample codes

-- Reference:
-- Khurram Soomro, Amir Roshan Zamir and Mubarak Shah, 
-- "UCF101: A Dataset of 101 Human Action Classes From Videos in The Wild.", 
-- CRCV-TR-12-01, November, 2012. 

-- ffmpeg usage:
-- Video{
--     [path = string]          -- path to video
--     [width = number]         -- width  [default = 224]
--     [height = number]        -- height  [default = 224]
--     [zoom = number]          -- zoom factor  [default = 1]
--     [fps = number]           -- frames per second  [default = 25]
--     [length = number]        -- length, in seconds  [default = 2]
--     [seek = number]          -- seek to pos. in seconds  [default = 0]
--     [channel = number]       -- video channel  [default = 0]
--     [load = boolean]         -- loads frames after conversion  [default = true]
--     [delete = boolean]       -- clears (rm) frames after load  [default = true]
--     [encoding = string]      -- format of dumped frames  [default = png]
--     [tensor = torch.Tensor]  -- provide a packed tensor (NxCxHxW or NxHxW), that bypasses path
--     [destFolder = string]    -- destination folder  [default = out_frames]
--     [silent = boolean]       -- suppress output  [default = false]
-- }

-- contact:
-- Min-Hung (Steve) Chen at <cmhungsteve@gatech.edu>
-- Chih-Yao Ma at <cyma@gatech.edu>
-- Last updated: 09/17/2016

require 'xlua'
require 'torch'
require 'ffmpeg'
require 'image'
require 'nn'
require 'cudnn' 
require 'cunn'
require 'cutorch'
t = require './transforms'

----------------------------------------------
-- 			User-defined parameters			--
----------------------------------------------
-- will combine to 'parse args' later
numStream = 2
numFrameSample = 25
sampleAll = false -- use all the frames or not
numSplit = 1
saveData = false
methodOF = 'TVL1' -- TVL1 | Brox
methodCrop = 'centerCrop' -- tenCrop | centerCrop
softMax = false
nCrops = (methodCrop == 'tenCrop') and 10 or 1
methodPred = 'scoreMean' -- classVoting | scoreMean
print('')
print('method for video prediction: ' .. methodPred)
if softMax then
	print('Using SoftMax layer')
end
print('Using '..methodCrop)

----------------------------------------------
-- 				Data paths				    --
----------------------------------------------
source = 'workstation' -- local | workstation
if source == 'local' then
	dirSource = '/home/cmhung/Code/'
elseif source == 'workstation' then	
	dirSource = '/home/chih-yao/Downloads/'
end

DIR = {}
dataFolder = {}
---- Temporal ----
if methodOF == 'Brox' then
	table.insert(DIR, {dirModel = dirSource..'Models-10fps/ResNet-Brox-sgd/', 
		dirDatabase = dirSource..'dataset/UCF-101/FlowMap-Brox/'})
elseif methodOF == 'TVL1' then
	table.insert(DIR, {dirModel = dirSource..'Models-10fps/ResNet-TVL1-sgd/', 
		dirDatabase = dirSource..'dataset/UCF-101/FlowMap-TVL1-crop20/'})
end

---- Spatial ----
table.insert(DIR, {dirModel = dirSource..'Models-10fps/ResNet-RGB-sgd/', 
	dirDatabase = dirSource..'dataset/UCF-101/RGB/'})

for nS=1,numStream do
	table.insert(dataFolder, paths.basename(DIR[nS].dirDatabase))
end

----------------
-- parse args --
----------------
op = xlua.OptionParser('%prog [options]')
op:option{'-f', '--fps', action='store', dest='fps',
          help='number of frames per second', default=25}
op:option{'-t', '--time', action='store', dest='seconds',
          help='length to process (in seconds)', default=2}
op:option{'-w', '--width', action='store', dest='width',
          help='resize video, width', default=320}
op:option{'-h', '--height', action='store', dest='height',
          help='resize video, height', default=240}
op:option{'-z', '--zoom', action='store', dest='zoom',
          help='display zoom', default=1}
op:option{'-m', '--mode', action='store', dest='mode',
          help='option for generating features (pred|feat)', default='pred'} -- prediction only
op:option{'-p', '--type', action='store', dest='type',
          help='option for CPU/GPU', default='cuda'}
op:option{'-i1', '--devid', action='store', dest='devid1',
          help='1st device ID (if using CUDA)', default=1}      
op:option{'-i2', '--devid', action='store', dest='devid2',
          help='2nd device ID (if using CUDA)', default=2}      
opt,args = op:parse()
print('fps: '..opt.fps)

----------------------------------------------
--         Input/Output information         --
----------------------------------------------
-- select the number of classes, groups & videos you want to use
numClass = 101
dimFeat = 2048
numTopN = 5

numStack = torch.Tensor(numStream)
nChannel = torch.Tensor(numStream)

-- Temporal
numStack[1] = 10
nChannel[1] = 2
-- Spatial
numStack[2] = 1
nChannel[2] = 3


----------------------------------------------
--  			Train/Test split			--
----------------------------------------------
groupSplit = {}
for sp=1,numSplit do
	if sp==1 then
		table.insert(groupSplit, {setTr = torch.Tensor({{8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25}}), 
			setTe = torch.Tensor({{1,2,3,4,5,6,7}})})
	elseif sp==2 then
		table.insert(groupSplit, {setTr = torch.Tensor({{1,2,3,4,5,6,7,15,16,17,18,19,20,21,22,23,24,25}}), 
			setTe = torch.Tensor({{8,9,10,11,12,13,14}})})
	elseif sp==3 then
		table.insert(groupSplit, {setTr = torch.Tensor({{1,2,3,4,5,6,7,8,9,10,11,12,13,14,22,23,24,25}}), 
			setTe = torch.Tensor({{15,16,17,18,19,20,21}})})
	end
end

-- Output information --
outTrain = {}
for sp=1,numSplit do
	--table.insert(outTrain, {name = 'data_'..opt.mode..'_train_'..dataFolder..'_'..methodCrop..'_sp'..sp..'.t7'})
	table.insert(outTrain, {name = 'data_'..opt.mode..'_train_'..methodCrop..'_sp'..sp..'.t7'})
end

outTest = {}
for sp=1,numSplit do
	--table.insert(outTest, {name = 'data_'..opt.mode..'_test_'..dataFolder..'_'..methodCrop..'_sp'..sp..'.t7'})
	table.insert(outTest, {name = 'data_'..opt.mode..'_test_'..methodCrop..'_sp'..sp..'.t7'})
end


------ model selection ------
-- ResNet model (from Torch) ==> need cudnn
modelName = 'model_best.t7'

modelPath = {}
for nS=1,numStream do
	table.insert(modelPath, DIR[nS].dirModel..modelName)
end
----------------------------------------------
-- 					Functions 				--
----------------------------------------------
meanstd = {}
-- Temporal
if dataFolder[1] == 'FlowMap-Brox' then
	-- 10 fps
	table.insert(meanstd, {mean = { 0.0091950063390791, 0.4922446721625, 0.49853131534726}, 
				std = { 0.0056229398806939, 0.070845543666524, 0.081589332546496}})
	-- -- 25 fps
	-- table.insert(meanstd, {mean = { 0.0091796917475333, 0.49176131835977, 0.49831646616289 },
 --               std = { 0.0056094466799444, 0.070888495268898, 0.081680047609585 }})

elseif dataFolder[1] == 'FlowMap-Brox-crop40' then
	table.insert(meanstd, {mean = { 0.0091936888040752, 0.49204453841557, 0.49857498097595},
      			std = { 0.0056320802048129, 0.070939325098903, 0.081698516724234}})
   elseif dataFolder[1] == 'FlowMap-Brox-crop20' then
   	table.insert(meanstd, {mean = { 0.0092002901164412, 0.49243926742539, 0.49851170257907},
                std = { 0.0056614266189997, 0.070921186231261, 0.081781848181796}})
elseif dataFolder[1] == 'FlowMap-Brox-M' then
	table.insert(meanstd, {mean = { 0.951, 0.918, 0.955 },
                std = { 0.043, 0.052, 0.044 }})
elseif dataFolder[1] == 'FlowMap-FlowNet' then
	table.insert(meanstd, {mean = { 0.009, 0.510, 0.515 },
                std = { 0.007, 0.122, 0.124 }})
elseif dataFolder[1] == 'FlowMap-FlowNet-M' then
	table.insert(meanstd, {mean = { 0.951, 0.918, 0.955 },
                std = { 0.043, 0.052, 0.044 }})
elseif dataFolder[1] == 'FlowMap-TVL1-crop20' then
	-- 10 fps	
	table.insert(meanstd, {mean = { 0.0078286737613148, 0.49277467447062, 0.42283539438139 },
                 std = { 0.0049402251681559, 0.060421647049655, 0.058913364961995 }})
	-- -- 25 fps
	-- table.insert(meanstd, {mean = { 0.0078368888567733, 0.49304171615406, 0.42294166284263 },
 --                  std = { 0.0049412518723573, 0.060508027119622, 0.058952390342379 }})
else
    error('no mean and std defined for temporal network... ')
end

-- Spatial
if dataFolder[2] == 'RGB' then
	-- 10 fps
	table.insert(meanstd, {mean = { 0.392, 0.376, 0.348 },
   				std = { 0.241, 0.234, 0.231 }})
	-- -- 25 fps
	-- table.insert(meanstd, {mean = { 0.39234371606738, 0.37576219443075, 0.34801909196893 },
 --               std = { 0.24149100687454, 0.23453123289779, 0.23117322727131 }})
else
    error('no mean and std defined for spatial network... ')
end

Crop = (methodCrop == 'tenCrop') and t.TenCrop or t.CenterCrop

----------------------------------------------
-- 					Class		        	--
----------------------------------------------
nameClass = paths.dir(DIR[1].dirDatabase) 
table.sort(nameClass)
numClassTotal = #nameClass -- 101 classes + "." + ".."

----------------------------------------------
-- 					Models		        	--
----------------------------------------------
devID = torch.Tensor(numStream)
devID[1] = opt.devid1 -- for temporal
devID[2] = opt.devid2 -- for spatial
net = {}

for nS=1,numStream do
	--- choose GPU ---
	cutorch.setDevice(devID[nS])
	print(sys.COLORS.red ..  '==> using GPU #' .. cutorch.getDevice())
	print(sys.COLORS.white ..  ' ')

	print ' '
	if nS == 1 then
		print '==> Loading the temporal model...'
	elseif nS == 2 then
		print '==> Loading the spatial model...'
	end
	local netTemp = torch.load(modelPath[nS]):cuda() -- Torch model
	
	------ model modification ------
	if opt.mode == 'feat' then
		-- Remove the fully connected layer
	    assert(torch.type(netTemp:get(#netTemp.modules)) == 'nn.Linear')
	    netTemp:remove(#netTemp.modules)
	elseif opt.mode == 'pred' then
		if softMax then
			softMaxLayer = cudnn.SoftMax():cuda()
		    netTemp:add(softMaxLayer)
		end
	end

	netTemp:evaluate() -- Evaluate mode

	table.insert(net, netTemp)

	-- print(netTemp)
	print ' '
end

----------------------------------------------
-- 			Loading ImageNet labels	  		--
----------------------------------------------
if opt.mode == 'pred' then
	-- imagenetLabel = require './imagenet'
	ucf101Label = require './ucf-101'
	table.sort(ucf101Label)
end
print ' '

--====================================================================--
--                     Run all the videos in UCF-101                  --
--====================================================================--
print '==> Processing all the videos...'

-- Load the intermediate feature data or generate a new one --
for sp=1,numSplit do
	-- Training data --
	if not (saveData and paths.filep(outTrain[sp].name)) then
		Tr = {} -- output
		Tr.name = {}
		Tr.path = {}
		Tr.featMats = torch.DoubleTensor()
		Tr.labels = torch.DoubleTensor()
		Tr.countVideo = 0
		Tr.countClass = 0
		Tr.c_finished = 0 -- different from countClass since there are also "." and ".."
	else
		Tr = torch.load(outTrain[sp].name) -- output
	end

	-- Testing data --
	if not (saveData and paths.filep(outTest[sp].name)) then
		Te = {} -- output
		Te.name = {}
		Te.path = {}
		Te.featMats = torch.DoubleTensor()
		Te.labels = torch.DoubleTensor()
		Te.countFrame = 0
		Te.countVideo = 0
		Te.countClass = 0
		Te.accFrameClass = {}
		Te.accFrameAll = 0
		Te.accVideoClass = {}
		Te.accVideoAll = 0
		Te.c_finished = 0 -- different from countClass since there are also "." and ".."

		Te.hitTestFrameAll = 0
		Te.hitTestVideoAll = 0

	else
		Te = torch.load(outTest[sp].name) -- output
	end
	collectgarbage()

	timerAll = torch.Timer() -- count the whole processing time

	if Tr.countClass == numClass and Te.countClass == numClass then
		print('The feature data of split '..sp..' is already in your folder!!!!!!')
	else

		for c=Te.c_finished+1, numClassTotal do
			if nameClass[c] ~= '.' and nameClass[c] ~= '..' then

				local hitTestFrameClass = 0
				local numTestFrameClass = 0
				local hitTestVideoClass = 0
				local numTestVideoClass = 0

				--==== Separate Spatial & Temporal ====--
				local hitTestFrameClassT = 0
				local hitTestVideoClassT = 0
				local hitTestFrameClassS = 0
				local hitTestVideoClassS = 0
						
				print('Current Class: '..c..'. '..nameClass[c])

				Tr.countClass = Tr.countClass + 1
				Te.countClass = Te.countClass + 1
			  	------ Data paths ------
			  	local dirClass = {}
			  	local nameSubVideo = {}

			  	for nS=1,numStream do
			  		dirClassTemp = DIR[nS].dirDatabase..nameClass[c]..'/'
			  		nameSubVideoTemp = paths.dir(dirClassTemp)
				  	table.sort(nameSubVideoTemp)

			  		table.insert(dirClass, dirClassTemp)
			  		table.insert(nameSubVideo, nameSubVideoTemp)
			  	end

			  	local numSubVideoTotal = #nameSubVideo[1] -- videos + '.' + '..'


			  	local timerClass = torch.Timer() -- count the processing time for one class
			  	
			  	for sv=1, numSubVideoTotal do
			      	--------------------
			      	-- Load the video --
			      	--------------------  
			      	local validName = nameSubVideo[1][sv] ~= '.' and nameSubVideo[1][sv] ~= '..' and nameSubVideo[2][sv] ~= '.' and nameSubVideo[2][sv] ~= '..'
			      	if validName then
			      		local videoName = {}

			        	for nS=1,numStream do
				        	local videoNameTemp = nameSubVideo[nS][sv]				        
			        		table.insert(videoName, videoNameTemp)
						end

			        	-- extract the group name
			            local i,j = string.find(videoName[1],'_g') -- find the location of the group info in the string
			            local videoGroup = tonumber(string.sub(videoName[1],j+1,j+2)) -- get the group#
			            local videoPathLocalT = nameClass[c]..'/'..videoName[1]
	
			          	----------------------------------------------
			          	--           	Process the video           --
			          	----------------------------------------------
			          	if opt.mode == 'pred' then 
				          	if groupSplit[sp].setTe:eq(videoGroup):sum() == 1 then -- testing data
				          		--== Read the video ==--
					        	local vidTensor = {}

					        	for nS=1,numStream do
					        		local videoPath = dirClass[nS]..videoName[nS]
						        	-- print('==> Loading the video: '..videoName[nS])
									local video = ffmpeg.Video{path=videoPath, fps=opt.fps, delete=true, destFolder='out_frames',silent=true}
									--video:play{} -- play the video
					        		table.insert(vidTensor, video:totensor{}) -- read the whole video & turn it into a 4D tensor (e.g. 150x3x240x320)
								end
					        	
					        	local numFrame = vidTensor[1]:size(1) -- same frame # for two streams
					        	-- print(numFrame)
					        	
					        	------ Video prarmeters (same for two streams) ------				        	
				        		local numFrameAvailable = numFrame - numStack[1] + 1 -- for 10-stacking
				        		local numFrameInterval = sampleAll and 1 or torch.floor(numFrameAvailable/numFrameSample)
				        		local numFrameUsed = sampleAll and numFrameAvailable or numFrameSample -- choose frame # for one video

				        		--== Prediction ==--
				          		Te.countVideo = Te.countVideo + 1
					          	
				          		------ Initialization of the prediction ------
				          		local predFrames = torch.Tensor(numFrameUsed):zero() -- e.g. 25
				          		local scoreFrames = torch.Tensor(numFrameUsed,numClass):zero() -- e.g. 25x101

				            	-- print '==> Begin predicting......'
				            	for i=1, numFrameUsed do
				            		local scoreFrame2S = torch.Tensor(numStream,numClass):zero() -- 2x101
				            		local f = (i-1)*numFrameInterval+5 -- current frame sample (middle in 10-stacking)
				            		for nS=1,numStream do
				            			cutorch.setDevice(devID[nS])
					        			--- transform ---
					        			transform = t.Compose{t.Scale(256), t.ColorNormalize(meanstd[nS], nChannel[nS]), Crop(224)}

					              		-- extract the input
					              		-- Temporal:	2-channel, 10-stacking
					              		-- Spatial:		3-channel, none-stacking
					              		local inFrames = vidTensor[nS][{{torch.floor(f-numStack[nS]/2)+1,torch.floor(f+numStack[nS]/2)},
					              		{3-(nChannel[nS]-1),3},{},{}}]

					              		-- change the dimension for the input to "transform" 
					              		-- Temporal:	20x240x320
					              		-- Spatial:		3x240x320					              		
					              		local netInput = torch.Tensor(inFrames:size(1)*nChannel[nS],opt.height,opt.width):zero()
					              		for x=0,numStack[nS]-1 do
					              			netInput[{{x*nChannel[nS]+1,(x+1)*nChannel[nS]}}] = inFrames[{{x+1},{},{},{}}]
					              		end

					         			local I = transform(netInput) -- e.g. 20x224x224 or 10x20x224x224 (tenCrop)
										local scoreFrame_now = torch.Tensor(1,numClass):zero() -- 1x101
					              		if (methodCrop == 'tenCrop') then
						              		local outputTen = net[nS]:forward(I:cuda()):float() -- 10x101
					              			scoreFrame_now = torch.mean(outputTen,1) -- 1x101
					              		else
					              			I = I:view(1, table.unpack(I:size():totable())) -- 1x20x224x224
					              			local output = net[nS]:forward(I:cuda()) -- 1x101
					              			scoreFrame_now = output
					              		end
					              		-- scoreFrame_now = cudnn.SoftMax():cuda():forward(scoreFrame_now)	-- add a softmax layer to convert the value to probability				              		
					              		scoreFrame2S[nS] = scoreFrame_now:float()					              		

					              	end
									scoreFrame2S_fusion = torch.mean(scoreFrame2S,1) -- 101 probabilities of the frame
									scoreFrames[i] = scoreFrame2S_fusion 
									local probLog, predLabels = scoreFrame2S_fusion:topk(numTopN, true, true) -- 5 (probabilities + labels)        
									local predFrame = predLabels[1][1] -- predicted label of the frame

									-- frame prediction
					            	local labelFrame = ucf101Label[predFrame]
					            	Te.countFrame = Te.countFrame + 1

					            	-- accumulate the score for frame prediction
					            	numTestFrameClass = numTestFrameClass + 1
					            	if labelFrame == nameClass[c] then
					            		hitTestFrameClass = hitTestFrameClass  + 1
					            	end
									predFrames[i] = predFrame			
					            end

					            -- prediction of this video
					            local predVideo

					            if methodPred == 'classVoting' then 
					            	local predVideoTensor = torch.mode(predFrames)
					            	predVideo = predVideoTensor[1]
								elseif methodPred == 'scoreMean' then
									local scoreMean = torch.mean(scoreFrames,1)
									local probLog, predLabels = scoreMean:topk(numTopN, true, true) -- 5 (probabilities + labels)
						           	predVideo = predLabels[1][1]
								end

					            local labelVideo = ucf101Label[predVideo]

				            	-- accumulate the score for video prediction
				            	numTestVideoClass = numTestVideoClass + 1
				            	if labelVideo == nameClass[c] then
				            		hitTestVideoClass = hitTestVideoClass  + 1
				            	end
				            	
				            end
			            elseif opt.mode == 'feat' then -- feature extraction
				        	-- TODO: two-stream
				          		local featMatsVideo = torch.DoubleTensor(1,dimFeat,numFrameUsed):zero() -- 1x2048x25
				            	--print '==> Generating the feature matrix......'
				            	for i=1, numFrameUsed do
					              	local f = (i-1)*numFrameInterval+1 -- current frame sample
					              	-- print(f)
					              	local inFrames = vidTensor2[{{f,f+numStack-1}}] -- 10x2x240x320
					              	local netInput = torch.Tensor(inFrames:size(1)*nChannel,opt.height,opt.width):zero() -- 20x240x320
					              	for x=0,numStack-1 do
					              		netInput[{{x*nChannel+1,(x+1)*nChannel}}] = inFrames[{{x+1},{},{},{}}]
					              	end
					         		local I = transform(netInput) -- 20x224x224 or 10x20x224x224 (tenCrop)

									local feat_now = torch.Tensor(1,dimFeat):zero()
					              	if tenCrop then
						            	local outputTen = net:forward(I:cuda()):float() -- 10x2048
					              		feat_now = torch.mean(outputTen,1) -- 1x2048
									else
					              		I = I:view(1, table.unpack(I:size():totable())) -- 1x20x224x224
					              		local output = net:forward(I:cuda()) -- 1x2048
					              		feat_now = output:float()
					              	end

				              		-- store the feature matrix for this video
							  		feat_now:resize(1,torch.numel(feat_now),1)
							  		featMatsVideo[{{},{},{i}}] = feat_now:double()

				            	end

				            	----------------------------------------------
			          			--          Train/Test feature split        --
			          			----------------------------------------------
				            	-- store the feature and label for the whole dataset

				            	if groupSplit[sp].setTe:eq(videoGroup):sum() == 0 then -- training data
				            		Tr.countVideo = Tr.countVideo + 1
				            		Tr.name[Tr.countVideo] = videoName
				            		Tr.path[Tr.countVideo] = videoPathLocal
				            		if Tr.countVideo == 1 then -- the first video
				            			Tr.featMats = featMatsVideo
				            			Tr.labels = torch.DoubleTensor(1):fill(Tr.countClass)
				            		else 					-- from the second or the following videos
				            			Tr.featMats = torch.cat(Tr.featMats,featMatsVideo,1)
				            			Tr.labels = torch.cat(Tr.labels,torch.DoubleTensor(1):fill(Tr.countClass),1)
				            		end			            	
				            	else -- testing data
				            		Te.countVideo = Te.countVideo + 1
				            		Te.name[Te.countVideo] = videoName
					            	Te.path[Te.countVideo] = videoPathLocal
				            		if Te.countVideo == 1 then -- the first video
				            			Te.featMats = featMatsVideo
				            			Te.labels = torch.DoubleTensor(1):fill(Te.countClass)
				            		else 					-- from the second or the following videos
				            			Te.featMats = torch.cat(Te.featMats,featMatsVideo,1)
				            			Te.labels = torch.cat(Te.labels,torch.DoubleTensor(1):fill(Te.countClass),1)
				            		end			            	
				            	end
				        end				        
			      	end
			      	collectgarbage()
			    end
				Te.c_finished = c -- save the index

				if opt.mode == 'pred' then 
					Te.hitTestFrameAll = Te.hitTestFrameAll + hitTestFrameClass
					print('Class frame accuracy: '..hitTestFrameClass/numTestFrameClass)
					print('Accumulated frame accuracy: '..Te.hitTestFrameAll/Te.countFrame)
					Te.accFrameClass[Te.countClass] = hitTestFrameClass/numTestFrameClass
					Te.accFrameAll = Te.hitTestFrameAll/Te.countFrame

					-- video prediction
					Te.hitTestVideoAll = Te.hitTestVideoAll + hitTestVideoClass
					print('Class video accuracy: '..hitTestVideoClass/numTestVideoClass)
					print('Accumulated video accuracy: '..Te.hitTestVideoAll/Te.countVideo)
					Te.accVideoClass[Te.countClass] = hitTestVideoClass/numTestVideoClass
					Te.accVideoAll = Te.hitTestVideoAll/Te.countVideo

				elseif opt.mode == 'feat' then
					print('Generated training data#: '..Tr.countVideo)
					print('Generated testing data#: '..Te.countVideo)
				end

			  	print('The elapsed time for the class '..nameClass[c]..': ' .. timerClass:time().real .. ' seconds')
			  	-- torch.save(outTrain[sp].name, Tr)
			  	
			  	if saveData then
					torch.save(outTrain[sp].name, Tr)
			  		torch.save(outTest[sp].name, Te)
				end

			  	collectgarbage()
			  	print(' ')
			end
		end
	end

	print('The total elapsed time in the split '..sp..': ' .. timerAll:time().real .. ' seconds')

	if opt.mode == 'pred' then 
		print('Total frame numbers: '..Te.countFrame)
		print('Total frame accuracy for the whole dataset: '..Te.hitTestFrameAll/Te.countFrame)
		print('Total video numbers: '..Te.countVideo)
		print('Total video accuracy for the whole dataset: '..Te.hitTestVideoAll/Te.countVideo)
	elseif opt.mode == 'feat' then
		print('The total training class numbers in the split'..sp..': ' .. Tr.countClass)
		print('The total training video numbers in the split'..sp..': ' .. Tr.countVideo)
		print('The total testing class numbers in the split'..sp..': ' .. Te.countClass)
		print('The total testing video numbers in the split'..sp..': ' .. Te.countVideo)
	end

	
	print ' '

	Tr = nil
	Te = nil
	collectgarbage()
end