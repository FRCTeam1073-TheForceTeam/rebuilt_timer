/// Stub implementation of record package classes for unsupported platforms
import 'dart:async';

class AudioEncoder {
  static const wav = 'wav';
  static const pcm16 = 'pcm16';
}

class RecordConfig {
  final String encoder;
  final int numChannels;
  final int sampleRate;

  const RecordConfig({
    required this.encoder,
    required this.numChannels,
    required this.sampleRate,
  });
}

class AudioRecorder {
  Future<Stream<dynamic>> startStream(RecordConfig config) async {
    return Stream.empty();
  }

  Future<void> stop() async {}
  void dispose() {}
}
