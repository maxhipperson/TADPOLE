% TADPOLE_BenchmarkMixedEffectsCov.m
%
% Submission using linear mixed effects model on ADAS13 and VentVol (+ APOE as covariate).
%
% Adapted by Razvan Marinescu from Daniel Alexander's SimpleForecastFPC02.m script
%============
% Date:
%   10 September 2017

%% Read in the TADPOLE data set and extract a few columns of salient information.
% Script requires that TADPOLE_D1_D2.csv is in the parent directory. Change if
% necessary
dataLocationD1D2 = '../'; % parent directory

tadpoleD1D2File = fullfile(dataLocationD1D2,'TADPOLE_D1_D2.csv');
tadpoleD3File = fullfile(dataLocationD1D2,'TADPOLE_D3.csv');
outputFile = 'TADPOLE_Submission_BenchmarkMixedEffectsCov_D3.csv';

TADPOLE_TableD12 = readTadpoleD1D2(tadpoleD1D2File);
TADPOLE_TableD3 = readTadpoleD3(tadpoleD3File);

TADPOLE_TableD12 = TADPOLE_TableD12(TADPOLE_TableD12.D2 == 0,:);

[ADAS13_Col, Ventricles_Col, ICV_Col, Ventricles_ICV_Col, ...
  CLIN_STAT_Col, RID_Col, ExamMonth_Col, AGE_Bl_Col, Viscode_Col, D3_Col] ...
  = extractSalientColumns(TADPOLE_TableD12);

TADPOLE_TableD3.ICV_bl = TADPOLE_TableD3.ICV;
[ADAS13_Col_D3, Ventricles_Col_D3, ICV_Col_D3, Ventricles_ICV_Col_D3, ...
  CLIN_STAT_Col_D3, RID_Col_D3, ExamMonth_Col_D3, AGE_Bl_Col_D3, Viscode_Col_D3, ~] ...
  = extractSalientColumns(TADPOLE_TableD3);

ADAS13_Col = [ADAS13_Col; ADAS13_Col_D3];
Ventricles_Col = [Ventricles_Col; Ventricles_Col_D3];
ICV_Col = [ICV_Col; ICV_Col_D3];
Ventricles_ICV_Col = [Ventricles_ICV_Col; Ventricles_ICV_Col_D3];
CLIN_STAT_Col = [CLIN_STAT_Col; CLIN_STAT_Col_D3];
RID_Col = [RID_Col; RID_Col_D3];
ExamMonth_Col = [ExamMonth_Col; ExamMonth_Col_D3];
D3_Col = [D3_Col; ones(size(ExamMonth_Col_D3))];
AGE_Bl_Col = [AGE_Bl_Col; AGE_Bl_Col_D3];
Viscode_Col = [Viscode_Col; Viscode_Col_D3];

% test there was no leakage of data from D12 that shoudn't be there
assert size(RID_Col(RID_Col == 2), 1) == 1
visCodeSubj2 = (Viscode_Col(RID_Col == 2));
assert visCodeSubj2{1} == 'm120'

% choose whether to plot the data.
plotDataFlag = 0;

%% Generate the forecast

display('Fitting Gaussian models...');

% estimate mean and variance of ADAS given CN, MCI, AD.

% Find all D1 entries that are NL and have ADAS13.
NL_and_ADAS13 = find(strcmp(CLIN_STAT_Col, 'NL') & ADAS13_Col>-1);
% Get the stats of the list of ADAS13 scores for these.
NL_ADAS13_mean = mean(ADAS13_Col(NL_and_ADAS13));
NL_ADAS13_std = std(ADAS13_Col(NL_and_ADAS13));

% Similarly get stats for ADAS13 of MCIs.
MCI_and_ADAS13 = find(strcmp(CLIN_STAT_Col, 'MCI') & ADAS13_Col>-1);
MCI_ADAS13_mean = mean(ADAS13_Col(MCI_and_ADAS13));
MCI_ADAS13_std = std(ADAS13_Col(MCI_and_ADAS13));

% And for AD
AD_and_ADAS13 = find(strcmp(CLIN_STAT_Col, 'Dementia') & ADAS13_Col>-1);
AD_ADAS13_mean = mean(ADAS13_Col(AD_and_ADAS13));
AD_ADAS13_std = std(ADAS13_Col(AD_and_ADAS13));

display('Generating forecast ...')

%* Get the list of subjects to forecast from D3 - the ordering is the
%* same as in the submission template.
d3Inds = find(D3_Col);
D3_SubjList = unique(RID_Col(d3Inds));
N_D3 = length(D3_SubjList);

nForecasts = 5*12; % forecast 5 years (60 months).
% 1. Clinical status forecasts
%    i.e. relative likelihood of NL, MCI, and Dementia (3 numbers)
CLIN_STAT_forecast = zeros(N_D3, nForecasts, 3);
% 2. ADAS13 forecasts 
%    (best guess, upper and lower bounds on 50% confidence interval)
ADAS13_forecast = zeros(N_D3, nForecasts, 3);
% 3. Ventricles volume forecasts 
%    (best guess, upper and lower bounds on 50% confidence interval)
Ventricles_ICV_forecast = zeros(N_D3, nForecasts, 3);

display_info = 1; % Useful for checking and debugging (see below)

%*** Some defaults where data is missing
% Missing data = typical volume +/- broad interval = 25000 +/- 20000
Ventricles_ICV_default_50pcMargin = 0.05;
ADAS_default_50pcMargin = 1;

% Need forecasts starting from Jan 2018 and up to (and including) Dec 2022. Those are
% months 217 to 276 (from Jan 2000).
monthsToForecastInd = 217:276;
predictionStartDate = datenum('01-Jan-2018');

nrVisits = size(RID_Col,1);
unqSubj = unique(RID_Col);
nrUnqSubj = length(unqSubj);

%% Fit Mixed Effects Model as follows:
% response (Y) -ADAS 13
% design matrix (X) - [1, AgeAtVisit, random effects] (1 random parameter per subject)
% Covariates - APOE4 (i.e. fit different slope for APOE=0 and APOE>=1)
% task: solve for beta: Y = Xb, where beta are the linear parameters 
% beta = [intercept, population_slope, random_effect_subj_1, random_effect_subj_2, ...]
% fixed parameters: intercept, population_slope
% random parameters: random_effect_subj_1, random_effect_subj_2, ...
% there is actually one extra degree of freedom (first parameter is unnecessary, but predictions should still be the same)


nrFixedParams = 2;
nrRandomParams = nrUnqSubj;

% Build the design matrix X
Xfull = zeros(nrVisits, nrFixedParams+nrRandomParams);

Xfull(:,1) = 1;
Xfull(:,2) = 0;

% Estimate the age at scan for every subject visit, since the AGE column
% only contains the age at baseline visit
for s=1:nrUnqSubj
  %Find the exams for this subject
  subj_rows = RID_Col == unqSubj(s);
  subj_exam_dates = ExamMonth_Col(subj_rows);
  m = min(subj_exam_dates);
  yearsDiff = (subj_exam_dates - m)/12;
  
  %X(subj_rows,2)
  
  assert(min(AGE_Bl_Col(subj_rows)) == max(AGE_Bl_Col(subj_rows)))
  Xfull(subj_rows,2) = AGE_Bl_Col(subj_rows) + yearsDiff;
  
  % also map the entries in the design matrix corresponding to individual
  % subjects
  Xfull(subj_rows, s+nrFixedParams) = 1;
end

Yadas = ADAS13_Col;
%filterMaskADAS = (Yadas ~= -1) & (~isnan(Xfull(:,3)));
filterMaskADAS = (Yadas ~= -1);
YadasFilt = Yadas(filterMaskADAS);
Xadas = Xfull(filterMaskADAS,:);

% Solve for beta using the Moore-Penrose pseudoinverse: b = (X'X)^{-1}X'Y
betaADAS = pinv(Xadas'*Xadas)*Xadas'*YadasFilt;
unqRIDsBeta = [-1*ones(nrFixedParams,1); unqSubj];

Yvents = Ventricles_ICV_Col;
filterMaskVents = (Yvents ~= -1) & (~isnan(Yvents)) & (~isnan(Xfull(:,3)));
YventsFilt = Yvents(filterMaskVents);
Xvents = Xfull(filterMaskVents,:);
betaVents = pinv(Xvents'*Xvents)*Xvents'*YventsFilt;

for i=1:N_D3
    
    subj_rows = find(RID_Col==D3_SubjList(i) & D3_Col);
    subj_exam_dates = ExamMonth_Col(subj_rows);
   
    % compute mixed effects model predictions
    m = min(subj_exam_dates);
    yearsDiff = (monthsToForecastInd - m)/12;
    XpredAgeCurr = (AGE_Bl_Col(subj_rows(1)) + yearsDiff)';
    
    XpredFull = [ones(size(XpredAgeCurr)), XpredAgeCurr, ones(size(XpredAgeCurr))];
    ADASpredCurrMixed = XpredFull * [betaADAS(1:nrFixedParams); betaADAS(unqRIDsBeta == D3_SubjList(i))];
    VentsPredCurrMixed = XpredFull * [betaVents(1:nrFixedParams); betaVents(unqRIDsBeta == D3_SubjList(i))];
    
    ADAS13_forecast(i,:,1) = ADASpredCurrMixed;
    ADAS13_forecast(i,:,2) = ADASpredCurrMixed - ADAS_default_50pcMargin;
    ADAS13_forecast(i,:,3) = ADASpredCurrMixed + ADAS_default_50pcMargin;
    
    Ventricles_ICV_forecast(i,:,1) = VentsPredCurrMixed;
    Ventricles_ICV_forecast(i,:,2) = VentsPredCurrMixed - Ventricles_ICV_default_50pcMargin;
    Ventricles_ICV_forecast(i,:,3) = VentsPredCurrMixed + Ventricles_ICV_default_50pcMargin;
    
    %* Construct status forecast
    % Estimate probabilities from ADAS13 score alone.
    NL_LikFromADAS13 = normpdf(ADAS13_forecast(i,:,1), NL_ADAS13_mean, NL_ADAS13_std);
    MCI_LikFromADAS13 = normpdf(ADAS13_forecast(i,:,1), MCI_ADAS13_mean, MCI_ADAS13_std);
    AD_LikFromADAS13 = normpdf(ADAS13_forecast(i,:,1), AD_ADAS13_mean, AD_ADAS13_std);
    
    CLIN_STAT_forecast(i,:,1) = NL_LikFromADAS13./(NL_LikFromADAS13+MCI_LikFromADAS13+AD_LikFromADAS13);
    CLIN_STAT_forecast(i,:,2) = MCI_LikFromADAS13./(NL_LikFromADAS13+MCI_LikFromADAS13+AD_LikFromADAS13);
    CLIN_STAT_forecast(i,:,3) = AD_LikFromADAS13./(NL_LikFromADAS13+MCI_LikFromADAS13+AD_LikFromADAS13); 
    
    if plotDataFlag
      exams_with_CLIN_STAT = [];
      exams_with_ADAS13 = find(ADAS13_Col(subj_rows)>0);
      exams_with_ventsv = find(Ventricles_ICV_Col(subj_rows)>0);
    
      % plot ADAS13
      figure(1);
      clf
      scatter(subj_exam_dates(exams_with_ADAS13)', ADAS13_Col(subj_rows(exams_with_ADAS13)),30,'magenta');
      hold on
      plot(monthsToForecastInd,ADAS13_forecast(i,:,1), 'r', 'LineWidth',2);
      hold on
      scatter(scanDateLB4_Col(subj_rows_lb4),LB4_Table.ADAS13(subj_rows_lb4),30,'blue')

      % plot Ventricles
      figure(2);
      clf
      scatter(subj_exam_dates(exams_with_ventsv)', Ventricles_ICV_Col(subj_rows(exams_with_ventsv)),30,'magenta');
      hold on
      plot(monthsToForecastInd,Ventricles_ICV_forecast(i,:,1), 'r', 'LineWidth',2);
      hold on
      scatter(scanDateLB4_Col(subj_rows_lb4),LB4_Table.Ventricles(subj_rows_lb4),30,'blue') 
    end
end

writePredictionsToFile(outputFile, nForecasts, N_D3, D3_SubjList, ...
  CLIN_STAT_forecast, ADAS13_forecast, Ventricles_ICV_forecast, predictionStartDate);

