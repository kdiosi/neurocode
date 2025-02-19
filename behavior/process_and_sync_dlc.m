function [tracking,field_names] = process_and_sync_dlc(varargin)
% Unpacks DLC CSV within subfolders
%
% Run this after you have exported deeplabcut csv results
%
% TODO:
%       -make option to just load and format csv without sync
%       -make more robust to file exist assumptions
%           (ex. MergePoints.events.mat, digitalIn.events.mat)
%       -make option for dlc csv in basepath
%       -make compatible with multi-animal tracking
%
%
% Ryan H 2022

p = inputParser;
p.addParameter('basepath',pwd,@isfolder);
p.addParameter('primary_coords',1,@isnumeric); % which tracker point do you want
p.addParameter('likelihood',.95,@isnumeric); % tracking quality thres [0-1]
p.addParameter('pulses_delta_range',0.01,@isnumeric); % range for ttls

p.parse(varargin{:});
primary_coords = p.Results.primary_coords;
basepath = p.Results.basepath;
likelihood = p.Results.likelihood;
pulses_delta_range = p.Results.pulses_delta_range;

basename = basenameFromBasepath(basepath);

if exist(fullfile(basepath,[basename,'.MergePoints.events.mat']),'file')
    load(fullfile(basepath,[basename,'.MergePoints.events.mat']));
    count = 1;
    for ii = 1:size(MergePoints.foldernames,2)
        if ~isempty(dir(fullfile(basepath,MergePoints.foldernames{ii},'*DLC*csv')))
            % locate file
            file = dir(fullfile(basepath,MergePoints.foldernames{ii},'*DLC*csv'));

            % if there are more than 1 csv, then it is likely to be a dlc
            % filtered file. If so, take the filtered csv
            if length(file) > 1
                file = dir(fullfile(basepath,MergePoints.foldernames{ii},'*DLC*filtered.csv'));
            end

            video_file = dir(fullfile(file(1).folder,'*.avi'));
            obj = VideoReader(fullfile(video_file.folder,video_file.name));
            fs = obj.FrameRate;

            % load csv with proper header
            df = load_dlc_csv(fullfile(file(1).folder,file(1).name));

            % locate columns with [x,y,likelihood]
            field_names = df.Properties.VariableNames;

            x_col = find(contains(field_names,'_x'));
            y_col = find(contains(field_names,'_y'));
            likelihood_col = find(contains(field_names,'_likelihood'));
            % filter out bad tracker points by likelihood thres
            for i = 1:length(x_col)
                idx = df{:,likelihood_col(i)} < likelihood;
                df{idx,x_col(i)} = NaN;
                df{idx,y_col(i)} = NaN;
            end
            ts = df{:,1}/fs;
            %             x = df{:,x_col(primary_coords)};
            %             y = df{:,y_col(primary_coords)};

            x = df{:,x_col};
            y = df{:,y_col};

            tempTracking{count} = sync_ttl(file.folder,x,y,ts,fs,pulses_delta_range);
            trackFolder(count) = ii;
            count = count + 1;
        end
    end
end

% Concatenate and sync timestamps
ts = []; subSessions = []; maskSessions = [];
if exist(fullfile(basepath,[basename,'.MergePoints.events.mat']),'file')
    load(fullfile(basepath,[basename,'.MergePoints.events.mat']));
    for ii = 1:length(trackFolder)
        if strcmpi(MergePoints.foldernames{trackFolder(ii)},tempTracking{ii}.folder)
            sumTs = tempTracking{ii}.timestamps + MergePoints.timestamps(trackFolder(ii),1);
            subSessions = [subSessions; MergePoints.timestamps(trackFolder(ii),1:2)];
            maskSessions = [maskSessions; ones(size(sumTs))*ii];
            ts = [ts; sumTs];
        else
            error('Folders name does not match!!');
        end
    end
else
    warning('No MergePoints file found. Concatenating timestamps...');
    for ii = 1:length(trackFolder)
        sumTs = max(ts)+ tempTracking{ii}.timestamps;
        subSessions = [subSessions; [sumTs(1) sumTs(end)]];
        ts = [ts; sumTs];
    end
end

% Concatenating tracking fields...
folder = []; samplingRate = []; description = [];

% check shape of data in all subsessions
for ii = 1:size(tempTracking,2)
    n_cols(ii) = size(tempTracking{ii}.position.x,2);
    n_rows(ii) = size(tempTracking{ii}.position.x,1);
end

% set up nan matrix as different sessions may have more columns
x = NaN(sum(n_rows),max(n_cols));
y = NaN(sum(n_rows),max(n_cols));

for ii = 1:size(tempTracking,2)
    % first iteration offset is 0 as no concat has happened yet
    if ii == 1
        row_offset = 0;
    end
    % determine shape of data to insert
    n_col = size(tempTracking{ii}.position.x,2);
    n_row = size(tempTracking{ii}.position.x,1);

    % insert data using above shape and offset
    x(row_offset+1:n_row+row_offset,1:n_col) = tempTracking{ii}.position.x;
    y(row_offset+1:n_row+row_offset,1:n_col) = tempTracking{ii}.position.y;

    % change offset to reflect last inserted data
    row_offset = n_row + row_offset;

    % metadata
    folder{ii} = tempTracking{ii}.folder;
    samplingRate = [samplingRate; tempTracking{ii}.samplingRate];
    description{ii} = tempTracking{ii}.description;
end

% pull out notes
for i = 1:length(tempTracking)
    notes{i} = [tempTracking{i}.folder,': ',tempTracking{i}.notes];
end

tracking.position.x = x;
tracking.position.y = y;
tracking.folders = folder;
tracking.samplingRate = samplingRate;
tracking.timestamps = ts;
tracking.notes = notes;
tracking.events.subSessions = subSessions;
tracking.events.subSessionsMask = maskSessions;
end

function [tracking] = sync_ttl(folder,x,y,ts,fs,pulses_delta_range)

if ~exist(fullfile(folder,'digitalIn.events.mat'),'file')
    if ~exist(fullfile(folder,'digitalin.dat'),'file')

        warning([fullfile(folder,'digitalin.dat'),'   does not exist'])

        disp('decide if you want to use tracking without ttls (not recommended), if so type dbcont')
        keyboard

        [~,folder_name] = fileparts(folder);
        tracking.position.x = x;
        tracking.position.y = y;
        tracking.timestamps = ts;
        tracking.originalTimestamps = ts;
        tracking.folder = folder_name;
        tracking.samplingRate = fs;
        tracking.description = '';
        tracking.notes = 'no ttls';
        return
    end
    digitalIn = getDigitalIn('all','folder',folder);
end
load(fullfile(folder,'digitalIn.events.mat'),'digitalIn')

Len = cellfun(@length, digitalIn.timestampsOn, 'UniformOutput', false);
[~,idx] = max(cell2mat(Len));
bazlerTtl = digitalIn.timestampsOn{idx};

%check for extra pulses of much shorter distance than they should
extra_pulses = diff(bazlerTtl)<((1/fs)-(1/fs)*pulses_delta_range);
bazlerTtl(extra_pulses) = [];

if isempty(bazlerTtl)
    warning('no real ttls, something went wrong')
    disp('fix the issue and type dbcont to continue')
    keyboard
end

basler_intan_diff = length(bazlerTtl) - size(x,1);

[x,y,ts,bazlerTtl,fs,notes] = match_basler_frames_to_ttl(bazlerTtl,basler_intan_diff,x,y,ts,fs);

[~,folder_name] = fileparts(folder);
tracking.position.x = x;
tracking.position.y = y;
tracking.timestamps = bazlerTtl;
tracking.originalTimestamps = ts;
tracking.folder = folder_name;
tracking.samplingRate = fs;
tracking.description = '';
tracking.notes = notes;
end

function [x,y,t,bazlerTtl,fs,notes] = match_basler_frames_to_ttl(bazlerTtl,basler_intan_diff,x,y,t,fs)

notes = [];

% match basler frames con ttl pulses
if (length(bazlerTtl) == size(x,1)) || abs(basler_intan_diff)<=2 %assumes 1 frame could be cut at 0 and 1 frame at end
    notes = 'N of frames match!!';
    warning(notes);

elseif basler_intan_diff>0 && abs(basler_intan_diff)<fs
    notes = [num2str(abs(length(bazlerTtl) - size(x,1))) ' of frames dont match, probably at the end of the recording'];
    warning(notes);
    bazlerTtl = bazlerTtl(1:size(x,1));
elseif basler_intan_diff<0 && abs(basler_intan_diff)<fs
    notes = [num2str(abs(length(bazlerTtl) - size(x,1))) ' of frames dont match, probably at the beggining of the recording'];
    warning(notes);
    x = x(1:length(bazlerTtl),:);
    y = y(1:length(bazlerTtl),:);
elseif basler_intan_diff<0 && abs(basler_intan_diff)>fs
    notes = [num2str(abs(size(x,1) - length(bazlerTtl)))...
        ' video frames without TTL... was the recording switched off before the camera? Cutting positions accordingly...'];
    warning(notes);
    x = x(1:length(bazlerTtl),:);
    y = y(1:length(bazlerTtl),:);

elseif abs(basler_intan_diff)>60*fs
    notes = 'More than 1 minute missalignment in total in this session...will interpolate ts';
    warning(notes);
    simulated_ts = linspace(min(bazlerTtl),max(bazlerTtl),length(x));
    bazlerTtl_new = interp1(bazlerTtl,bazlerTtl,simulated_ts);
    bazlerTtl = bazlerTtl_new';
    fs = mode(diff(bazlerTtl));

elseif abs(basler_intan_diff)>2*fs
    notes = 'More than 2 seconds missalignment in total in this session...will adjust to the closer one...';
    warning(notes);
    if basler_intan_diff>0
        bazlerTtl = bazlerTtl(1:size(x,1));
    else
        x = x(1:length(bazlerTtl),:);
        y = y(1:length(bazlerTtl),:);
    end
elseif isempty(bazlerTtl)
    bazlerTtl = t;
    notes = 'no ttls';
    warning(notes);
else
    notes = 'Unnoticed problem with Camera/Intan... I would go back and check both step by step';
    warning(notes);
end
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

try [amplifier_channels, notes, aux_input_channels, spike_triggers,...
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