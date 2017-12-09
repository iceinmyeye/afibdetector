%%TODO
% Delay separating training sets from testing sets as much as possible
% Maybe classify between AFIB and normal within the same series (i.e. use
% first 3 hours to train, other 7 to test --> Need to screen for records
% with many episodes)

%% Cleanup
clc
clear all
close all

%% Import data
disp('Importing data...');

% Adds the WFDB toolkit folder to path so that we can use rdsamp and rdann
fullpath = mfilename('fullpath');
k = strfind(fullpath, mfilename);
fullfolder = fullpath(1:k-1);
addpath(genpath(fullfolder));

% Move to outside the WFDB folder so that it can find our records
prev_folder = pwd;
cd(fullfolder)

% Names of all the records we're going to use
recordNames = {'04015', '04043', '04048', '04126', '04746', '04908', ...
               '04936', '05091', '05121', '05261', '06426', '06453', ...
               '06995', '07162', '07859', '07879', '07910', '08215', ...
               '08219', '08378', '08405', '08434', '08455'};

numRecords = length(recordNames);
           
% Loads all the records into a 'records' structure
for recIndex = 1:length(recordNames)
    recName = char(recordNames(recIndex));
    disp(recName);
    recPath = strcat('mit-bih\', recName);    
    
    % Actually read everything    
    [r.signalmV,r.Fs,r.tmSecs]=rdsamp(recPath);
    [r.annSamples,r.anntype,r.subtype,r.chan,r.num,r.comments] = rdann(recPath, 'atr');
    r.annVec = get_annotation_vector(length(r.signalmV), r.annSamples, r.comments);
        
    % Pack everything we read into our records structure
    records.(strcat('rec', recName)) = r;    
end

% Go back to where we were before, if it matters
cd(prev_folder);

%% Pick random records to be our training sets
disp('Marking records as training sets...');
learningSetCount = 15;

% Randomly pick 'learningSetCount' records to be learning sets
learningSets = false(numRecords);
learningSets(1:learningSetCount) = 1;
learningSets = learningSets(randperm(length(learningSets)));

i = 1;
recordNames = fieldnames(records);
for recordName=recordNames'         
    % Mark it as a learning set
    records.(recordName{1}).isLearningSet = learningSets(i);    
    i = i + 1;
end

%% Break ECG1 signal records into windows
disp('Separating ECG1 into windows and extracting their classes...');
windowSizeSeconds = 4;

recordNames = fieldnames(records);
for recordName=recordNames'    
    record = records.(recordName{1});
    disp(recordName{1});
    
    samplingFreq = record.Fs;
    windowSize = windowSizeSeconds * samplingFreq;
        
    maxNumWindows = floor(length(record.signalmV(:, 1)) / windowSize);
    numWindows = 1;

    % Pre-allocate maximum size for speed
    classes = zeros(maxNumWindows, 1);
    windows = zeros(maxNumWindows, windowSize);

    % Break record into windows
    for i=1:maxNumWindows        
        rangeStart = 1 + (i-1)*windowSize;
        rangeEnd = i*windowSize;    

        sampleAnns = record.annVec(rangeStart:rangeEnd);
        
        % If there are other arrythmias in this window, discard it and go
        % to the next window
        if sum(sampleAnns==2) > 0
            continue
        end
        
        % If most of the samples are marked as AFIB, mark the window as AFIB        
        classes(numWindows) = sum(sampleAnns) > windowSize/2;
        windows(numWindows, :) = record.signalmV(rangeStart:rangeEnd, 1);        
        
        numWindows = numWindows + 1;
    end    
    
    % Rewind last iteration just before we left the for loop
    numWindows = numWindows - 1;
    
    % Discard extra lines
    windows = windows(1:numWindows, :);
    classes = classes(1:numWindows);
    
    records.(recordName{1}).signalmVWindows = windows;
    records.(recordName{1}).actualClasses = classes;
end

%% Get Welch PSD estimator from the windows and store them back into records
disp('Getting Welch PSD estimator from ECG1 windows...');

recordNames = fieldnames(records);
for recordName=recordNames'     
    record = records.(recordName{1});
    
    [psds, f] = pwelch(record.signalmVWindows',[],[],[],250);
    psds = psds';
    
    % Keep track of how many frequency bands pwelch returned. This has
    % been determined to be the same for all datasets
    numberFrequencyBands = size(psds, 2);
    
    %Store PSDs with each row being a window, each column being a frequency
    %(that is, a variable)
    %psds+(psds==0) first sets to 1 elements that are zero
    records.(recordName{1}).PSDs = 10*log10(psds+(psds==0));    
    
    nans = sum(isnan(records.(recordName{1}).PSDs));
    infs = sum(isinf(records.(recordName{1}).PSDs));
    
    %min(min(records.(recordName{1}).PSDs))
    
    if nans
        disp(strcat(recordName{1}, ' has NaNs in its PSDs'));
    end
    
    if infs
        disp(strcat(recordName{1}, ' has Infs in its PSDs'));
    end
end

%% Extract the learning sets from the data to train our SVM
disp('Separating learning set...');

trainingPSDs = zeros(1, numberFrequencyBands);
trainingClasses = zeros(1, 1);

recordNames = fieldnames(records);
for recordName=recordNames'     
    record = records.(recordName{1});
    
    if record.isLearningSet
        % Stack all training PSDs on the same matrix
        trainingPSDs = [trainingPSDs; record.PSDs];
        trainingClasses = [trainingClasses; record.actualClasses];        
    end
end

trainingPSDs = trainingPSDs(2:end, :);
trainingClasses = trainingClasses(2:end, :);

disp('Training set dimensions (samples x frequencies): ');
size(trainingPSDs)

%% Perform PCA of psds

numPrincipalComponents = 0;

% Only perform PCA if we pick numPrincipalComponents different than zero
if numPrincipalComponents ~= 0
    disp('Performing PCA from window PSDs...');
    
    [coeff,score,latent,tsquared,explained] = pca(trainingPSDs);

    % We'll use this later to convert new observations into PCA components
    pcaMean = mean(trainingPSDs);
    pcaCoeffs = inv(coeff');

    % Get first 10 components
    trainingPSDsPCA = score(:, 1:numPrincipalComponents);

    % Map test records to PCA components
    recordNames = fieldnames(records);
    for recordName=recordNames'     
        record = records.(recordName{1});
        testPSDs = record.PSDs;        
        numSamples = size(testPSDs, 1);

        if ~record.isLearningSet       
            % Actually do the mapping of samples. Check test_pca for proof
            meanPCAmat = repmat(pcaMean, numSamples, 1);
            pcaTestPSDs = (testPSDs - meanPCAmat) * pcaCoeffs;
            pcaTestPSDs = pcaTestPSDs(:, 1:numPrincipalComponents);
            
            records.(recordName{1}).PSDs = pcaTestPSDs;
        end
    end

    disp('Post-PCA training set dimensions (samples x components): ');
    size(trainingPSDsPCA)
    
    % Overwrite our training PSDs so that the rest of the pipeline never
    % needs to care if we did PCA or not
    trainingPSDs = trainingPSDsPCA;
end

%% Build a SVM classifier with the training set
% disp('Training SVM model...');
% 
% SVMModel = fitcsvm(trainingPSDs, ...
%                    trainingClasses, ...
%                    'KernelFunction', ...
%                    'linear');

%% Predict the classes of each records' windows and stores them in the records
% disp('Classifying with SVM model...');
% 
% totalConfMat = zeros(2, 2);
% 
% recordNames = fieldnames(records);
% for recordName=recordNames'     
%     record = records.(recordName{1});
%     
%     if ~record.isLearningSet        
%         % Predict all PSDs of the record at once using our SVM model
%         [predictedClasses, scoreForEachClass] = predict(SVMModel, record.PSDs);
%         
%         actualClasses = record.actualClasses;
%         
%         confMat = zeros(2, 2);        
%         confMat(1, 1) = sum(~predictedClasses & ~actualClasses);
%         confMat(2, 2) = sum(predictedClasses & actualClasses);
%         confMat(1, 2) = sum(predictedClasses & ~actualClasses);
%         confMat(2, 1) = sum(~predictedClasses & actualClasses);        
%         
%         totalConfMat = totalConfMat + confMat;
%         
%         % Store prediction results into records
%         records.(recordName{1}).predictedClass = predictedClasses;
%         records.(recordName{1}).predictionScores = scoreForEachClass; 
%     end
% end
% 
% totalConfMat
% totalAccuracy = (totalConfMat(1, 1) + totalConfMat(2, 2)) / sum(sum(totalConfMat))

%% Try a linear classifier instead
disp('Classifying with a linear classifier...');

totalConfMat = zeros(2, 2);

recordNames = fieldnames(records);
for recordName=recordNames'     
    record = records.(recordName{1});
    
    if ~record.isLearningSet        
        % Predict all PSDs of the record at once using our SVM model
        predictedClasses = classify(record.PSDs, ...
                                    trainingPSDs, ...
                                    trainingClasses, ...
                                    'linear');
        
        actualClasses = record.actualClasses;
        
        confMat = zeros(2, 2);        
        confMat(1, 1) = sum(~predictedClasses & ~actualClasses);
        confMat(2, 2) = sum(predictedClasses & actualClasses);
        confMat(1, 2) = sum(predictedClasses & ~actualClasses);
        confMat(2, 1) = sum(~predictedClasses & actualClasses);        
        
        totalConfMat = totalConfMat + confMat;
        
        % Store prediction results into records
        records.(recordName{1}).predictedClass = predictedClasses;
    end
end

totalConfMat
totalAccuracy = (totalConfMat(1, 1) + totalConfMat(2, 2)) / sum(sum(totalConfMat))






















