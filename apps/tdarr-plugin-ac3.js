const details = () => ({
  id: "Tdarr_Plugin_Add_AC3_Track",
  Stage: "Pre-processing",
  Name: "Add AC3 5.1 track alongside DTS-HD MA",
  Type: "Audio",
  Operation: "Transcode",
  Description: "Adds an AC3 640kbps 5.1 audio track when file only has DTS/DTS-HD MA audio. Keeps original track untouched.",
  Version: "1.0",
  Tags: "pre-processing,ffmpeg,audio only",
  Inputs: [],
});

const plugin = (file) => {
  const response = {
    processFile: false,
    preset: "",
    container: ".mkv",
    handBrakeMode: false,
    FFmpegMode: true,
    reQueueAfter: false,
    infoLog: "",
  };

  if (!file.ffProbeData || !file.ffProbeData.streams) {
    response.infoLog += "No stream data found. Skipping.\n";
    return response;
  }

  const audioStreams = file.ffProbeData.streams.filter(
    (s) => s.codec_type === "audio"
  );

  if (audioStreams.length === 0) {
    response.infoLog += "No audio streams found. Skipping.\n";
    return response;
  }

  const hasAC3 = audioStreams.some(
    (s) => s.codec_name === "ac3" || s.codec_name === "eac3"
  );

  if (hasAC3) {
    response.infoLog += "AC3/EAC3 track already exists. Skipping.\n";
    return response;
  }

  const hasDTS = audioStreams.some(
    (s) =>
      s.codec_name === "dts" ||
      s.profile === "DTS-HD MA" ||
      s.profile === "DTS-HD HRA" ||
      s.codec_name === "truehd"
  );

  if (!hasDTS) {
    response.infoLog += "No DTS/DTS-HD MA/TrueHD tracks found. Skipping.\n";
    return response;
  }

  const dtsStream = audioStreams.find(
    (s) =>
      s.codec_name === "dts" ||
      s.profile === "DTS-HD MA" ||
      s.profile === "DTS-HD HRA" ||
      s.codec_name === "truehd"
  );

  response.infoLog += "Found " + (dtsStream.profile || dtsStream.codec_name) + " track without AC3 fallback. Adding AC3 5.1 640k track.\n";
  response.processFile = true;

  const streamIdx = dtsStream.index;
  const newIdx = audioStreams.length;
  response.preset = "-map 0 -map 0:" + streamIdx + " -c copy -c:a:" + newIdx + " ac3 -b:a:" + newIdx + " 640k -ac 6 -metadata:s:a:" + newIdx + " title=\"AC3 5.1 (TV Compatible)\"";

  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
