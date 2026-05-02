/* eslint-disable no-plusplus */
const details = () => ({
  name: 'Add AC3 5.1 Track Alongside DTS-HD MA',
  description: 'Adds an AC3 640kbps 5.1 audio track when file only has DTS/DTS-HD MA/TrueHD audio. Keeps original track untouched.',
  style: {
    borderColor: 'orange',
  },
  tags: 'audio',
  isStartPlugin: false,
  pType: '',
  requiresVersion: '2.11.01',
  sidebarPosition: -1,
  icon: 'faVolumeUp',
  inputs: [],
  outputs: [
    {
      number: 1,
      tooltip: 'AC3 track added',
    },
    {
      number: 2,
      tooltip: 'File skipped (already has AC3 or no DTS/TrueHD)',
    },
  ],
});

const plugin = async (args) => {
  const lib = require('../../../../../methods/lib')();
  args.inputs = lib.loadDefaultValues(args.inputs, details);

  const { CLI } = require('../../../../../FlowHelpers/1.0.0/cliUtils');
  const { getContainer, getFileName, getPluginWorkDir } = require('../../../../../FlowHelpers/1.0.0/fileUtils');

  const streams = args.inputFileObj.ffProbeData?.streams || [];
  const audioStreams = streams.filter((s) => s.codec_type === 'audio');

  if (audioStreams.length === 0) {
    args.jobLog('No audio streams found. Skipping.');
    return {
      outputFileObj: args.inputFileObj,
      outputNumber: 2,
      variables: args.variables,
    };
  }

  const hasAC3 = audioStreams.some(
    (s) => s.codec_name === 'ac3' || s.codec_name === 'eac3',
  );

  if (hasAC3) {
    args.jobLog('AC3/EAC3 track already exists. Skipping.');
    return {
      outputFileObj: args.inputFileObj,
      outputNumber: 2,
      variables: args.variables,
    };
  }

  const dtsStream = audioStreams.find(
    (s) => s.codec_name === 'dts'
      || s.profile === 'DTS-HD MA'
      || s.profile === 'DTS-HD HRA'
      || s.codec_name === 'truehd',
  );

  if (!dtsStream) {
    args.jobLog('No DTS/DTS-HD MA/TrueHD tracks found. Skipping.');
    return {
      outputFileObj: args.inputFileObj,
      outputNumber: 2,
      variables: args.variables,
    };
  }

  const label = dtsStream.profile || dtsStream.codec_name;
  args.jobLog(`Found ${label} track without AC3 fallback. Adding AC3 5.1 640k track.`);

  const container = getContainer(args.inputFileObj._id);
  const outputFilePath = `${getPluginWorkDir(args)}/${getFileName(args.inputFileObj._id)}.${container}`;

  const streamIdx = dtsStream.index;

  const spawnArgs = [
    '-i', args.inputFileObj._id,
    '-map', '0',
    '-map', `0:${streamIdx}`,
    '-c', 'copy',
    `-c:a:${audioStreams.length}`, 'ac3',
    `-b:a:${audioStreams.length}`, '640k',
    '-ac:a:' + audioStreams.length, '6',
    `-metadata:s:a:${audioStreams.length}`, 'title=AC3 5.1 (TV Compatible)',
    '-y',
    outputFilePath,
  ];

  const cli = new CLI({
    cli: args.ffmpegPath,
    spawnArgs,
    spawnOpts: {},
    jobLog: args.jobLog,
    outputFilePath,
    inputFileObj: args.inputFileObj,
    logFullCliOutput: args.logFullCliOutput,
    updateWorker: args.updateWorker,
    args,
  });

  const res = await cli.runCli();

  if (res.cliExitCode !== 0) {
    args.jobLog('FFmpeg failed. Skipping file.');
    return {
      outputFileObj: args.inputFileObj,
      outputNumber: 2,
      variables: args.variables,
    };
  }

  args.jobLog('AC3 5.1 track added successfully.');

  return {
    outputFileObj: { _id: outputFilePath },
    outputNumber: 1,
    variables: args.variables,
  };
};

module.exports.details = details;
module.exports.plugin = plugin;
