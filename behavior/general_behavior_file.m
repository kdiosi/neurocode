function general_behavior_file(varargin)
% converts multiple tracking data types to the standard described in cellexplorer
% https://cellexplorer.org/datastructure/data-structure-and-format/#behavior
%
% This was writed to standardize xy coordinates and trials in several older data sets
%
% check extract_tracking below to preview methods. Can be further
% customized.
%
% Currently compatible with the following sources:
%   .whl
%   posTrials.mat
%   basename.posTrials.mat
%   position.behavior.mat
%   position_info.mat
%   _TXVt.mat
%   tracking.behavior.mat
%   Tracking.behavior.mat
%   DeepLabCut .csv
%   optitrack.behavior.mat
%   optitrack .csv file
%   *_Behavior*.mat file from crcns_pfc-2_data
%
%
% TODO:
%       -make so you can choose (w/ varargin) which method to use (some sessions meet several)
%           This will require making each method into a sub/local function
%
%       -Needs refactored as many functions are redundant.
%           ex. kilosort dir skipper is written twice, .whl files in subdirs
%
% Ryan H 2021

p=inputParser;
addParameter(p,'basepath',pwd); % single or many basepaths in cell array or uses pwd
addParameter(p,'fs',39.0625); % behavioral tracking sample rate (will detect fs for newer datasets)
addParameter(p,'force_overwrite',false); % overwrite previously saved data (will remove custom fields)
addParameter(p,'force_run',false); % run even if animal.behavior already exists
addParameter(p,'save_mat',true); % save animal.behavior.mat
addParameter(p,'primary_coords_dlc',1); % deeplabcut tracking point to extract (extracts all, but main x and y will be this)
addParameter(p,'likelihood_dlc',.95); % deeplabcut likelihood threshold
addParameter(p,'force_format','none'); % force loading type (options: 'optitrack','dlc')
addParameter(p,'clean_tracker_jumps',false); % option to manually clean tracker jumps
addParameter(p,'convert_xy_to_cm',false); % option to convert xy to cm (best if used with clean_tracker_jumps)
addParameter(p,'maze_sizes',[]); % list of maze sizes (x-dim) per non-sleep epoch (if same maze & cam pos over epochs use single number)

parse(p,varargin{:});
basepaths = p.Results.basepath;
fs = p.Results.fs;
force_overwrite = p.Results.force_overwrite;
force_run = p.Results.force_run;
save_mat = p.Results.save_mat;
primary_coords_dlc = p.Results.primary_coords_dlc;
likelihood_dlc = p.Results.likelihood_dlc;
force_format = p.Results.force_format;
clean_tracker_jumps = p.Results.clean_tracker_jumps;
convert_xy_to_cm = p.Results.convert_xy_to_cm;
maze_sizes = p.Results.maze_sizes;

if ~iscell(basepaths)
    basepaths = {basepaths};
end

% iterate over basepaths and extract tracking
for i = 1:length(basepaths)
    basepath = basepaths{i};
    basename = basenameFromBasepath(basepath);
    if exist([basepath,filesep,[basename,'.animal.behavior.mat']],'file') &&...
            ~force_run
        continue
    end
    disp(basepath)
    main(basepath,...
        basename,...
        fs,...
        save_mat,...
        force_overwrite,...
        primary_coords_dlc,...
        likelihood_dlc,...
        force_format,...
        clean_tracker_jumps,...
        convert_xy_to_cm,...
        maze_sizes);
end
end

function behavior = main(basepath,...
    basename,...
    fs,...
    save_mat,...
    force_overwrite,...
    primary_coords,...
    likelihood,...
    force_format,...
    clean_tracker_jumps,...
    convert_xy_to_cm,...
    maze_sizes)

if exist([basepath,filesep,[basename,'.animal.behavior.mat']],'file') &&...
        ~force_overwrite
    load([basepath,filesep,[basename,'.animal.behavior.mat']],'behavior');
    disp([basepath,filesep,[basename,'.animal.behavior.mat already detected. Loading file...']]);
end

% call extract_tracking which contains many extraction methods
[t,x,y,z,v,trials,trialsID,units,source,linearized,fs,notes,extra_points,stateNames,states] =...
    extract_tracking(basepath,basename,fs,primary_coords,likelihood,force_format);

load([basepath,filesep,[basename,'.session.mat']],'session');

% package results
behavior.sr = fs;
behavior.timestamps = t';
behavior.position.x = x';
behavior.position.y = y';
behavior.position.z = z';
behavior.position.linearized = linearized';
behavior.position.units = units;
behavior.speed = v';
behavior.acceleration = [0,diff(behavior.speed)];
behavior.trials = trials;
behavior.trials = trialsID;
behavior.states = states;
behavior.stateNames = stateNames;
behavior.notes = notes;
behavior.epochs = session.epochs;
behavior.processinginfo.date = datetime("today");
behavior.processinginfo.function = 'general_behavioral_file.mat';
behavior.processinginfo.source = source;

% deeplabcut will often have many tracking points, add them here
if ~isempty(extra_points)
    for field = fieldnames(extra_points)'
        behavior.position.(field{1}) = extra_points.(field{1})';
    end
end

% pulls up gui to circle maze and remove outlier points
if clean_tracker_jumps
    if ~isfield(session.epochs{1},'environment')
        disp('you need to specify your environments in session')
        session = gui_session(session);
    end
    % load epochs and locate non-sleep epochs
    epoch_df = load_epoch('basepath',basepath);
    epoch_df = epoch_df(epoch_df.environment ~= "sleep",:);
    start = epoch_df.startTime;
    stop = epoch_df.stopTime;
    
    good_idx = manual_trackerjumps(behavior.timestamps,...
        behavior.position.x,...
        behavior.position.y,...
        start,...
        stop,...
        basepath,...
        'darkmode',true);
    
    behavior.position.x(~good_idx) = NaN;
    behavior.position.y(~good_idx) = NaN;
end

% option to convert to cm from pixels
if convert_xy_to_cm
    if isempty(maze_sizes)
        error('you must provide maze sizes')
    end
    
    % locate tracker points to scale
    pos_fields = fields(behavior.position);
    pos_fields = pos_fields(structfun(@numel,behavior.position) == length(behavior.position.x));
    
    % if more than 1 maze size, convert epoch by epoch
    if length(maze_sizes) > 1
        maze_sizes_i = 1;
        for ep = 1:length(session.epochs)
            if ~contains(session.epochs{ep}.environment,'sleep')
                
                [idx,~,~] = InIntervals(behavior.timestamps,...
                    [session.epochs{ep}.startTime,session.epochs{ep}.stopTime]);
                
                files = dir(fullfile(basepath,session.epochs{ep}.name,'*.avi'));
                if isempty(files)
                    warning(['could not fine video: ',fullfile(basepath,session.epochs{ep}.name,'*.avi')])
                    warning('using range of x tracking point')
                    pos_range = max(behavior.position.x(idx)) - min(behavior.position.x(idx));
                else
                    pos_range = maze_distance_gui(fullfile(files.folder,files.name));
                end
                convert_pix_to_cm_ratio = (pos_range / maze_sizes(maze_sizes_i));
                maze_sizes_i = maze_sizes_i + 1;

                % add convert_pix_to_cm_ratio to epochs in behavior file
                behavior.epochs{ep}.pix_to_cm_ratio = convert_pix_to_cm_ratio;

                % iterate over each tracker point
                for pos_fields_i = 1:length(pos_fields)
                    behavior.position.(pos_fields{pos_fields_i})(idx) =...
                        behavior.position.(pos_fields{pos_fields_i})(idx) / convert_pix_to_cm_ratio;
                end
            end
        end
    else
        load(fullfile(basepath,[basename,'.MergePoints.events.mat']),'MergePoints')
        for folder = MergePoints.foldernames
            files = dir(fullfile(basepath,folder{1},'*.avi'));
            if ~isempty(files)
                break
            end
        end
        if isempty(files)
            warning('could not fine video: *.avi')
            warning('using range of x tracking point')
            pos_range = max(behavior.position.x) - min(behavior.position.x);
        else
            pos_range = maze_distance_gui(fullfile(files.folder,files.name));
        end
        convert_pix_to_cm_ratio = (pos_range / maze_sizes);

        % add convert_pix_to_cm_ratio to epochs in behavior file
        for ep = 1:length(session.epochs)
            if ~contains(session.epochs{ep}.environment,'sleep')
                behavior.epochs{ep}.pix_to_cm_ratio = convert_pix_to_cm_ratio;
            end
        end

        % iterate over each tracker point
        for pos_fields_i = 1:length(pos_fields)
            behavior.position.(pos_fields{pos_fields_i}) =...
                behavior.position.(pos_fields{pos_fields_i}) / convert_pix_to_cm_ratio;
        end
    end
    behavior.position.units = 'cm';
    
    v = LinearVelocity([behavior.timestamps',behavior.position.x',behavior.position.y']);
    behavior.speed = v(:,2)';
    behavior.acceleration = [0,diff(behavior.speed)];
end

if save_mat
    save([basepath,filesep,[basename,'.animal.behavior.mat']],'behavior');
end
end

function [t,x,y,z,v,trials,trialsID,units,source,linearized,fs,notes,extra_points,stateNames,states] =...
    extract_tracking(basepath,basename,fs,primary_coords,likelihood,force_format)

t = [];
x = [];
y = [];
z = [];
v = [];
trials = [];
trialsID = [];
units = [];
source = [];
linearized = [];
notes = [];
extra_points = [];
stateNames = [];
states = [];
% below are many methods on locating tracking data from many formats


% search for DLC csv within basepath and subdirs, but not kilosort folder (takes too long)
if exist(fullfile(basepath,[basename,'.MergePoints.events.mat']),'file')
    
    load(fullfile(basepath,[basename,'.MergePoints.events.mat']),'MergePoints')
    for k = 1:length(MergePoints.foldernames)
        dlc_flag(k) = ~isempty(dir(fullfile(basepath,MergePoints.foldernames{k},'*DLC*.csv')));
    end
    files = dir(basepath);
    files = files(~contains({files.name},'Kilosort'),:);
    dlc_flag(k+1) = ~isempty(dir(fullfile(files(1).folder,'*DLC*.csv')));
else
    dlc_flag = false;
end

% search for optitrack flag
if exist(fullfile(basepath,[basename,'.MergePoints.events.mat']),'file')
    
    load(fullfile(basepath,[basename,'.MergePoints.events.mat']))
    for k = 1:length(MergePoints.foldernames)
        opti_flag(k) = ~isempty(dir(fullfile(basepath,MergePoints.foldernames{k},'*.tak')));
    end
    files = dir(basepath);
    files = files(~contains({files.name},'Kilosort'),:);
    opti_flag(k+1) = ~isempty(dir(fullfile(files(1).folder,'*.tak')));
else
    opti_flag = false;
end

if any(dlc_flag) || contains(force_format,'dlc')
    disp('detected deeplabcut')
    [tracking,field_names] = process_and_sync_dlc('basepath',basepath,...
        'primary_coords',primary_coords,...
        'likelihood',likelihood);
    
    t = tracking.timestamps;
    fs = 1/mode(diff(t));
    
    x = tracking.position.x(:,primary_coords);
    y = tracking.position.y(:,primary_coords);
    
    % multiple tracking points will likely exist, extract here
    x_col = field_names(contains(field_names,'_x'));
    y_col = field_names(contains(field_names,'_y'));
    extra_points = struct();
    for i = 1:length(x_col)
        extra_points.([x_col{i},'_point']) = tracking.position.x(:,i);
        extra_points.([y_col{i},'_point']) = tracking.position.y(:,i);
    end
    
    units = 'pixels';
    source = 'deeplabcut';
    
    if length(t) > length(x)
        t = t(1:length(x));
    elseif length(x) > length(t)
        x = x(1:length(t));
        y = y(1:length(t));
        % adjust other tracker points
        for name = fields(extra_points)'
            extra_points.(name{1}) = extra_points.(name{1})(1:length(t));
        end
    end
    
    if isfield(tracking, 'events')
        if isfield(tracking.events,'subSessions')
            trials = tracking.events.subSessions;
        end
    end
    notes = ['primary_coords: ',num2str(primary_coords),...
        ', likelihood: ',num2str(likelihood)];
    notes = {notes,tracking.notes};
    
elseif any(opti_flag) || contains(force_format,'optitrack')
    disp('detected optitrack .tak file...')
    disp('using optitrack .csv file')
    
    % load in merge points to iter over later
    load(fullfile(basepath,[basename,'.MergePoints.events.mat']),'MergePoints')
    % load in digital in to get video ttl time stamps
    try
        load(fullfile(basepath,[basename,'.DigitalIn.events.mat']),'digitalIn')
    catch
        try
            load(fullfile(basepath,'digitalIn.events.mat'),'digitalIn')
        catch
            load(fullfile(basepath,[basename,'.session.mat']),'session')
            digitalIn = getDigitalIn('all','fs',session.extracellular.sr,'folder',basepath);
        end
    end
    % get ttl timestamps from digitalin using the channel with the most signals
    Len = cellfun(@length, digitalIn.timestampsOn, 'UniformOutput', false);
    [~,idx] = max(cell2mat(Len));
    digitalIn_ttl = digitalIn.timestampsOn{idx};
    
    % calc sample rate from ttls
    fs = 1/mode(diff(digitalIn_ttl));
    
    %check for extra pulses of much shorter distance than they should
    extra_pulses = diff(digitalIn_ttl)<((1/fs)-(1/fs)*0.01);
    digitalIn_ttl(extra_pulses) = [];
    
    % iter over mergepoint folders to extract tracking
    for k = 1:length(MergePoints.foldernames)
        % search for optitrack .tak file as there may be many .csv files
        if ~isempty(dir(fullfile(basepath,MergePoints.foldernames{k},'*.csv')))
            % locate the .tak file in this subfolder
            file = dir(fullfile(basepath,MergePoints.foldernames{k},'*.csv'));
            % use func from cellexplorer to load tracking data
            % here we are using the .csv
            try
                optitrack = optitrack2buzcode('basepath', basepath,...
                    'basename', basename,...
                    'filenames',fullfile(MergePoints.foldernames{k},[file.name]),...
                    'unit_normalization',1,...
                    'saveMat',false,...
                    'saveFig',false,...
                    'plot_on',false);
            catch
                warning(fullfile(MergePoints.foldernames{k},[file.name]),' IS NOT OPTITRACK FILE')
                continue
            end
            % find timestamps within current session
            ts_idx = digitalIn_ttl >= MergePoints.timestamps(k,1) & digitalIn_ttl <= MergePoints.timestamps(k,2);
            ts = digitalIn_ttl(ts_idx);
            
            % cut-to-size method of syncing ttls to frames
            try
                t = [t,ts(1:length(optitrack.position.x))'];
            catch
                t = [t,ts'];
                x = [x,optitrack.position.x(1:length(ts))];
                y = [y,optitrack.position.y(1:length(ts))];
                z = [z,optitrack.position.z(1:length(ts))];
                continue
            end
            
            % align ttl timestamps,
            % there always are differences in n ttls vs. n coords, so we interp
            %             simulated_ts = linspace(min(ts),max(ts),length(optitrack.position.x));
            %             ts = interp1(ts,ts,simulated_ts);
            %             t = [t,ts];
            
            % store xyz
            x = [x,optitrack.position.x];
            y = [y,optitrack.position.y];
            z = [z,optitrack.position.z];
        end
    end
    
    % transpose xyz to accommodate all the other formats
    x = x';
    y = y';
    z = z';
    t = t';
    
    % update unit and source metadata
    units = 'cm';
    source = 'optitrack .csv file';
    
elseif exist([basepath,filesep,[basename,'.optitrack.behavior.mat']],'file')
    disp('detected optitrack')
    load([basepath,filesep,[basename,'.optitrack.behavior.mat']],'optitrack')
    t = optitrack.timestamps;
    x = optitrack.position.x';
    y = optitrack.position.y';
    z = optitrack.position.z';
    fs = optitrack.sr;
    units = 'cm';
    source = 'optitrack.behavior.mat';
    
    % standard whl file xyxy format
elseif exist([basepath,filesep,[basename,'.whl']],'file')
    disp('detected .whl')
    positions = load([basepath,filesep,[basename,'.whl']]);
    t = (0:length(positions)-1)'/fs;
    positions(positions == -1) = NaN;
    % find led with best tracking
    [x,y] = find_best_columns(positions,fs);
    units = 'cm';
    source = '.whl';
    if exist(fullfile(basepath,'trials.mat'),'file')
        trials = load(fullfile(basepath,'trials.mat'));
        trials = trials.trials;
    end
    if exist(fullfile(basepath,[basename,'-TrackRunTimes.mat']),'file')
        trials = load(fullfile(basepath,[basename,'-TrackRunTimes.mat']));
        trials = trials.trackruntimes;
    end
    
    % sometimes whl files are within fmat folder and have different name
elseif exist(fullfile(basepath,'fmat',[animalFromBasepath(basepath),basename,'.whl']),'file')
    disp('detected .whl')
    positions = load(fullfile(basepath,'fmat',[animalFromBasepath(basepath),basename,'.whl']));
    t = (0:length(positions)-1)'/fs;
    positions(positions == -1) = NaN;
    try
        [x,y] = find_best_columns(positions,fs);
    catch
        x = positions(:,1);
        y = positions(:,2);
    end
    units = 'cm';
    source = '.whl';
    if exist(fullfile(basepath,'fmat','trials.mat'),'file')
        trials = load(fullfile(basepath,'fmat','trials.mat'));
        try
            trials = trials.trials;
        catch
            temp_trials = [];
            for name = fieldnames(trials)'
                temp_trials = [temp_trials;trials.(name{1})];
            end
            [~,idx] = sort(temp_trials(:,1));
            trials = temp_trials(idx,:);
        end
    end
    
    % sometimes whl files are within fmat folder and have different name
elseif exist(fullfile(basepath,'fmat',[basename,'.whl']),'file')
    disp('detected .whl')
    positions = load(fullfile(basepath,'fmat',[basename,'.whl']));
    t = (0:length(positions)-1)'/fs;
    positions(positions == -1) = NaN;
    % find led with best tracking
    [x,y] = find_best_columns(positions,fs);
    units = 'cm';
    source = '.whl';
    if exist(fullfile(basepath,'fmat','trials.mat'),'file')
        trials = load(fullfile(basepath,'fmat','trials.mat'));
        trials = trials.trials;
    end
    
elseif ~isempty(dir(fullfile(basepath,'fmat', '*.whl')))
    disp('detected .whl')
    filelist = dir(fullfile(basepath,'fmat', '*.whl'));
    positions = load(fullfile(filelist(1).folder,filelist(1).name));
    t = (0:length(positions)-1)'/fs;
    positions(positions == -1) = NaN;
    % find led with best tracking
    [x,y] = find_best_columns(positions,fs);
    units = 'cm';
    source = '.whl';
    if exist(fullfile(basepath,'fmat','trials.mat'),'file')
        trials = load(fullfile(basepath,'fmat','trials.mat'));
        trials = trials.trials;
    elseif exist(fullfile(basepath,[basename,'.trials.mat']),'file')
        trials = load(fullfile(basepath,[basename,'.trials.mat']));
        temp_trials = [];
        for name = fieldnames(trials)'
            temp_trials = [temp_trials;trials.(name{1})];
        end
        [~,idx] = sort(temp_trials(:,1));
        trials = temp_trials(idx,:);
    end
    % postTrials format, processed linearized data
elseif exist([basepath,filesep,['posTrials.mat']],'file')
    disp('detected posTrials.mat')
    load([basepath,filesep,['posTrials.mat']],'posTrials');
    positions = [posTrials{1};posTrials{2}];
    [~,idx] = sort(positions(:,1));
    positions = positions(idx,:);
    t = positions(:,1);
    x = [];
    y = [];
    linearized = positions(:,2);
    units = 'normalize';
    source = 'posTrials.mat';
    fs = 1/mode(diff(t));
    if exist(fullfile(basepath,[basename,'.trials.mat']),'file')
        trials = load(fullfile(basepath,[basename,'.trials.mat']));
        temp_trials = [];
        for name = fieldnames(trials)'
            temp_trials = [temp_trials;trials.(name{1})];
        end
        [~,idx] = sort(temp_trials(:,1));
        trials = temp_trials(idx,:);
    end
elseif exist([basepath,filesep,[basename,'.posTrials.mat']],'file')
    disp('detected basename.posTrials.mat')
    load([basepath,filesep,[basename,'.posTrials.mat']],'posTrials');
    
    positions = [];
    linearized = [];
    states_temp = [];
    trials = [];
    for ep = 1:length(posTrials)
        positions = [positions;posTrials{ep}.pos];
        linearized = [linearized;posTrials{ep}.linpos];
        states_temp = [states_temp;repmat({posTrials{ep}.type},length(posTrials{ep}.linpos),1)];
        trials = [trials;posTrials{ep}.int];
    end
    
    [~,idx] = sort(positions(:,1));
    positions = positions(idx,:);
    
    [~,idx] = sort(linearized(:,1));
    linearized = linearized(idx,1);
    
    states_temp = states_temp(idx,:);
    
    stateNames = unique(states_temp)';
    states = zeros(1,length(states_temp));
    for i = 1:length(stateNames)
        states(contains(states_temp,stateNames{i})) = i;
    end
    
    t = positions(:,1);
    x = positions(:,2);
    y = positions(:,3);
    
    units = 'normalize';
    source = 'basename.posTrials.mat';
    
    % posTrials is sometimes moved
elseif exist([basepath,filesep,['oldfiles\posTrials.mat']],'file')
    disp('detected posTrials.mat')
    load([basepath,filesep,['oldfiles\posTrials.mat']],'posTrials');
    positions = [posTrials{1};posTrials{2}];
    [~,idx] = sort(positions(:,1));
    positions = positions(idx,:);
    t = positions(:,1);
    x = [];
    y = [];
    linearized = positions(:,2);
    units = 'normalize';
    source = 'posTrials.mat';
    fs = 1/mode(diff(t));
    
    if exist(fullfile(basepath,[basename,'.trials.mat']),'file')
        trials = load(fullfile(basepath,[basename,'.trials.mat']));
        temp_trials = [];
        for name = fieldnames(trials)'
            temp_trials = [temp_trials;trials.(name{1})];
        end
        [~,idx] = sort(temp_trials(:,1));
        trials = temp_trials(idx,:);
    end
    
    % .position.behavior file with x,y,linear and more
elseif exist([basepath,filesep,[basename,'.position.behavior.mat']],'file')
    disp('detected position.behavior.mat')
    load([basepath,filesep,[basename,'.position.behavior.mat']],'position')
    t = position.timestamps;
    x = position.position.x;
    y = position.position.y;
    linearized = position.position.lin;
    units = position.units;
    
    if position.units == "m"
        x = x*100;
        y = y*100;
        linearized = linearized*100;
        units = 'cm';
    end
    source = 'position.behavior.mat';
    fs = 1/mode(diff(t));
    
    if exist([basepath,filesep,['position_info.mat']],'file')
        load([basepath,filesep,['position_info.mat']],'pos_inf')
        trials = [cellfun(@(x) min(x),pos_inf.ts_ep),...
            cellfun(@(x) max(x),pos_inf.ts_ep)];
    end
    
    % position_info files have xy and linearized data
elseif exist([basepath,filesep,['position_info.mat']],'file')
    disp('detected position_info.mat')
    load([basepath,filesep,['position_info.mat']],'pos_inf')
    t = pos_inf.ts';
    x = pos_inf.x;
    y = pos_inf.y;
    linearized = pos_inf.lin_pos;
    trials = [cellfun(@(x) min(x),pos_inf.ts_ep),...
        cellfun(@(x) max(x),pos_inf.ts_ep)];
    units = 'cm';
    source = 'position_info.mat';
    fs = 1/mode(diff(t));
    
    %  _TXVt files have time, x, v, and trials
elseif exist([basepath,filesep,[basename,'_TXVt.mat']],'file')
    disp('detected _TXVt.mat')
    load([basepath,filesep,[basename,'_TXVt.mat']],'TXVt')
    t = TXVt(:,1);
    linearized = TXVt(:,2);
    x = TXVt(:,2);
    y = [];
    for trial_n = unique(TXVt(:,4))'
        trial_ts = TXVt(TXVt(:,4) == trial_n,1);
        trials = [trials;[min(trial_ts),max(trial_ts)]];
    end
    units = 'cm';
    source = '_TXVt.mat';
    fs = 1/mode(diff(t));
elseif exist([basepath,filesep,[basename,'.tracking.behavior.mat']],'file')
    disp('detected tracking.behavior.mat')
    load([basepath,filesep,[basename,'.tracking.behavior.mat']],'tracking')
    t = tracking.timestamps;
    fs = 1/mode(diff(t));
    
    if isfield(tracking.position,'x') && isfield(tracking.position,'y') &&...
            isfield(tracking.position,'z')
        x = tracking.position.x * 100;
        y = tracking.position.z * 100;
        z = tracking.position.y * 100;
        notes = "z to y and y to z";
        units = 'cm';
        source = '.tracking.behavior.mat';
    elseif isfield(tracking.position,'x') && isfield(tracking.position,'y')
        x = tracking.position.x;
        y = tracking.position.y;
        units = 'cm';
        source = '.tracking.behavior.mat';
    elseif isfield(tracking.position,'x1') && isfield(tracking.position,'y1')
        positions = [tracking.position.x1,...
            tracking.position.y1,...
            tracking.position.x2,...
            tracking.position.y2];
        [x,y] = find_best_columns(positions,fs);
        if range(x) <= 1
            units = 'normalized';
        elseif range(x) > 1
            units = 'pixels';
        end
        source = '.Tracking.behavior.mat';
        if length(t) > length(x)
            t = t(1:length(x));
            warning('Different number of ts and coords! Check data source to verify')
        end
    end
    if isfield(tracking, 'events')
        if isfield(tracking.events,'subSessions')
            trials = tracking.events.subSessions;
        end
    end
    
    if ~isempty(dir([basepath,filesep,[basename,'.*Trials.mat']]))
        filelist = dir([basepath,filesep,[basename,'.*Trials.mat']]);
        for file = filelist'
            load(fullfile(file.folder,file.name))
            if ~isempty(trials)
                trials = trials.int;
                break
            end
        end
    end
    % sometimes whl files have yet to be concatenated and are in subfolders
    % elseif ~isempty(dir(fullfile(basepath, '**\*.whl')))
    %     filelist = dir(fullfile(basepath, '**\*.whl'));
    %     for file = filelist'
    %         disp(file)
    %     end
    %
elseif exist([basepath,filesep,[basename,'.Behavior.mat']],'file')
    disp('detected .Behavior.mat')
    load([basepath,filesep,[basename,'.Behavior.mat']],'behavior')
    t = behavior.timestamps;
    x = behavior.position.x;
    y = behavior.position.y;
    linearized = behavior.position.lin;
    units = 'cm';
    source = '.Behavior.mat';
    
elseif ~isempty(dir(fullfile(basepath,'**','*_Behavior*.mat')))
    % crcns_pfc-2_data behavior file
    
    file = dir(fullfile(basepath,'**','*_Behavior*.mat'));
    load(fullfile(file(1).folder,file(1).name),'whlrld');
    t = (0:length(whlrld)-1)'/fs;
    whlrld(whlrld(:,1) == -1,1:4) = NaN;
    % find led with best tracking
    [x,y] = find_best_columns(whlrld,fs);
    units = 'cm';
    source = '.whl';
    %     trials = whlrld(:,6)+1;
    linearized = whlrld(:,7);
else
    warning('No video detected...')
    disp('attempting to add ttls from digitalIn')
    if exist(fullfile(basepath,[basename,'.MergePoints.events.mat']),'file')
        load(fullfile(basepath,[basename,'.MergePoints.events.mat']),'MergePoints');
        count = 1;
        for ii = 1:size(MergePoints.foldernames,2)
            tempTracking{count} = sync_ttl(basepath,MergePoints.foldernames{ii});
            trackFolder(count) = ii;
            count = count + 1;
        end
    end
    % Concatenate and sync timestamps
    t = []; subSessions = []; maskSessions = [];
    if exist(fullfile(basepath,[basename,'.MergePoints.events.mat']),'file')
        load(fullfile(basepath,[basename,'.MergePoints.events.mat']),'MergePoints');
        for ii = 1:length(trackFolder)
            if strcmpi(fullfile(basepath,MergePoints.foldernames{trackFolder(ii)}),tempTracking{ii}.folder)
                sumTs = tempTracking{ii}.timestamps + MergePoints.timestamps(trackFolder(ii),1);
                subSessions = [subSessions; MergePoints.timestamps(trackFolder(ii),1:2)];
                maskSessions = [maskSessions; ones(size(sumTs))*ii];
                t = [t; sumTs];
            else
                error('Folders name does not match!!');
            end
        end
        fs = 1/mode(diff(t));
    else
        warning('No MergePoints file found. Concatenating timestamps...');
        if ~exist('trackFolder','var')
           warning('No trackFolder found. returning...');
           return 
        end
        for ii = 1:length(trackFolder)
            sumTs = max(t)+ tempTracking{ii}.timestamps;
            subSessions = [subSessions; [sumTs(1) sumTs(end)]];
            t = [t; sumTs];
        end
        fs = 1/mode(diff(t));
    end
end

% trials can sometimes have extra columns
if size(trials,2) > 2
    trials = trials(:,1:2);
end
% to help find if trials are index instead of sec
isaninteger = @(x)isfinite(x) & x==floor(x);
% check if trials are integers, if so, they are index instead of sec
if all(isaninteger(trials)) & ~isempty(trials)
    trials = t(trials);
end
% if the max trial is greater than the available time, they are index
% if max(trials(:))-max(t) > 10 & all(isaninteger(trials)) & ~isempty(trials)
%     trials = t(trials);
% end

% get velocity
try
    try
        v = LinearVelocity([t,x,y]);
        v = v(:,2);
        if length(v) ~= length(x)
            DX = Diff([t,x,y],'smooth',0);
            Y = DX(:,2:3).*DX(:,2:3);
            v = sqrt(Y(:,1)+Y(:,2));
        end
    catch
        [~,idx,idx1] = unique(t);
        v = LinearVelocity([t(idx),x(idx),y(idx)]);
        v = v(idx1,:);
        v = v(:,2);
    end
catch
    try
        v = LinearVelocity([t,linearized,linearized*0]);
        v = v(:,2);
    catch
        warning('no tracking data')
    end
end

end

function tracking = sync_ttl(basepath,folder)

if ~exist(fullfile(basepath,folder,'digitalIn.events.mat'),'file')
    digitalIn = getDigitalIn('all','folder',fullfile(basepath,folder));
    if isempty(digitalIn)
        tracking.timestamps = [];
        tracking.folder = fullfile(basepath,folder);
        tracking.samplingRate = [];
        tracking.description = '';
        return
    end
end
load(fullfile(fullfile(basepath,folder),'digitalIn.events.mat'))

Len = cellfun(@length, digitalIn.timestampsOn, 'UniformOutput', false);
[~,idx] = max(cell2mat(Len));
bazlerTtl = digitalIn.timestampsOn{idx};
fs = 1/mode(diff(bazlerTtl));
%check for extra pulses of much shorter distance than they should
extra_pulses = diff(bazlerTtl)<((1/fs)-(1/fs)*0.01);
bazlerTtl(extra_pulses) = [];

[~,folder_name] = fileparts(folder);
tracking.timestamps = bazlerTtl;
tracking.folder = fullfile(basepath,folder);
tracking.samplingRate = fs;
tracking.description = '';
end

% find led with best tracking
function [x,y] = find_best_columns(positions,fs)
for col = 1:size(positions,2)
    x_test = medfilt1(positions(:,col),round(fs/2),'omitnan');
    R(col) = corr(positions(:,col),x_test, 'rows','complete');
end
[~,idx] = max([mean(R(1:2)), mean(R(3:4))]);
columns{1} = [1,2];
columns{2} = [3,4];
x = positions(:,columns{idx}(1));
y = positions(:,columns{idx}(2));
%     [~,idx] = min([sum(isnan(positions(:,1))),sum(isnan(positions(:,3)))]);

end

function [digitalIn] = getDigitalIn(ch,varargin)
% [pul, val, dur] = getDigitalIn(d,varargin)
%
% Find digital In pulses
%
% INPUTS
% ch            Default all.
% <OPTIONALS>
% fs            Sampling frequency (in Hz), default 30000, or try to
%               recover for rhd
% offset        Offset subtracted (in seconds), default 0.
% periodLag     How long a pulse has to be far from other pulses to be consider a different stimulation period (in seconds, default 5s)
% filename      File to get pulses from. Default, digitalin.dat file with folder
%               name in current directory
%
%
% OUTPUTS
%               digitalIn - events struct with the following fields
% ints          C x 2  matrix with pulse times in seconds. First column of C
%               are the beggining of the pulses, second column of C are the end of
%               the pulses.
% dur           Duration of the pulses. Note that default fs is 30000.
% timestampsOn  Beggining of all ON pulses
% timestampsOff Beggining of all OFF pulses
% intsPeriods   Stimulation periods, as defined by perioLag
%
% MV-BuzsakiLab 2019
% Based on Process_IntanDigitalChannels by P Petersen

% Parse options
if exist('ch') ~= 1
    ch = 'all';
end

p = inputParser;
addParameter(p,'fs',[],@isnumeric)
addParameter(p,'offset',0,@isnumeric)
addParameter(p,'filename',[],@isstring)
addParameter(p,'periodLag',5,@isnumeric)
addParameter(p,'folder',pwd,@isfolder)

parse(p, varargin{:});
fs = p.Results.fs;
offset = p.Results.offset;
filename = p.Results.filename;
lag = p.Results.periodLag;
folder = p.Results.folder;

if ~isempty(dir(fullfile(folder,'*.xml')))
    %sess = bz_getSessionInfo(pwd,'noPrompts',true);
    sess = getSession('basepath',fileparts(folder));
end
if ~isempty(dir(fullfile(folder,'*DigitalIn.events.mat')))
    disp('Pulses already detected! Loading file.');
    file = dir(fullfile(folder,'*DigitalIn.events.mat'));
    load(fullfile(file.folder,file.name));
    return
end

if isempty(filename)
    filename=dir(fullfile(folder,'digitalIn.dat'));
    filename = filename.name;
elseif exist('filename','var')
    disp(['Using input: ',filename])
else
    disp('No digitalIn file indicated...');
end

try
    [amplifier_channels, notes, aux_input_channels, spike_triggers,...
        board_dig_in_channels, supply_voltage_channels, frequency_parameters,board_adc_channels] =...
        read_Intan_RHD2000_file_bz('basepath',folder);
    fs = frequency_parameters.board_dig_in_sample_rate;
catch
    disp('File ''info.rhd'' not found. (Type ''help <a href="matlab:help loadAnalog">loadAnalog</a>'' for details) ');
end

disp('Loading digital channels...');
m = memmapfile(fullfile(folder,filename),'Format','uint16','writable',false);
digital_word2 = double(m.Data);
clear m
Nchan = 16;
Nchan2 = 17;
for k = 1:Nchan
    tester(:,Nchan2-k) = (digital_word2 - 2^(Nchan-k))>=0;
    digital_word2 = digital_word2 - tester(:,Nchan2-k)*2^(Nchan-k);
    test = tester(:,Nchan2-k) == 1;
    test2 = diff(test);
    pulses{Nchan2-k} = find(test2 == 1);
    pulses2{Nchan2-k} = find(test2 == -1);
    data(k,:) = test;
end
digital_on = pulses;
digital_off = pulses2;
disp('Done!');

for ii = 1:size(digital_on,2)
    if ~isempty(digital_on{ii})
        % take timestamp in seconds
        digitalIn.timestampsOn{ii} = digital_on{ii}/fs;
        digitalIn.timestampsOff{ii} = digital_off{ii}/fs;
        
        % intervals
        d = zeros(2,max([size(digitalIn.timestampsOn{ii},1) size(digitalIn.timestampsOff{ii},1)]));
        d(1,1:size(digitalIn.timestampsOn{ii},1)) = digitalIn.timestampsOn{ii};
        d(2,1:size(digitalIn.timestampsOff{ii},1)) = digitalIn.timestampsOff{ii};
        if d(1,1) > d(2,1)
            d = flip(d,1);
        end
        if d(2,end) == 0; d(2,end) = nan; end
        digitalIn.ints{ii} = d;
        digitalIn.dur{ii} = digitalIn.ints{ii}(2,:) - digitalIn.ints{ii}(1,:); % durantion
        
        clear intsPeriods
        intsPeriods(1,1) = d(1,1); % find stimulation intervals
        intPeaks =find(diff(d(1,:))>lag);
        for jj = 1:length(intPeaks)
            intsPeriods(jj,2) = d(2,intPeaks(jj));
            intsPeriods(jj+1,1) = d(1,intPeaks(jj)+1);
        end
        intsPeriods(end,2) = d(2,end);
        digitalIn.intsPeriods{ii} = intsPeriods;
    end
end

if exist('digitalIn','var')==1
    xt = linspace(0,size(data,2)/fs,size(data,2));
    data = flip(data);
    data = data(1:size(digitalIn.intsPeriods,2),:);
    
    h=figure;
    imagesc(xt,1:size(data,2),data);
    xlabel('s'); ylabel('Channels'); colormap gray
    mkdir(fullfile(folder,'Pulses'));
    saveas(h,fullfile(folder,'Pulses','digitalIn.png'));
    
    save(fullfile(folder,'digitalIn.events.mat'),'digitalIn');
else
    digitalIn = [];
end

end
