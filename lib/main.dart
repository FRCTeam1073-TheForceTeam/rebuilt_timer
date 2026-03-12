import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fft/fft.dart';

// Import record package - available on Android/iOS
import 'package:record/record.dart'
    show AudioRecorder, AudioEncoder, RecordConfig;

void _debugLog(String message) {
  if (kDebugMode) {
    print(message);
  }
}

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rebuilt Timer',
      theme: ThemeData(
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.grey.shade400,
            foregroundColor: Colors.black,
          ),
        ),
      ),
      home: const HomePage(title: 'Rebuilt Timer'),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.title});
  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AudioRecorder? _recorder;
  bool _isListeningToMic = false;
  String? _myColor; // Track team color: 'red' or 'blue'

  // State machine for bell pattern detection
  // Track count: 0, 1, 2, or 3 bells detected
  int _bellCount = 0;
  final List<int> _bellPatternTimes =
      []; // timestamps of each pattern transition
  final List<int> _bellPeakTimes =
      []; // timestamps of successful bell peak detections (for 0.4s spacing validation)
  int? _bellDetectionStartTime; // timestamp when current bell detection started
  bool _suppressingForBell =
      false; // are we currently suppressing chunks for bell duration?
  int?
  _suppressionEndTime; // timestamp when suppression ends (for timeout detection)
  int?
  _lastValidBellStartTime; // timestamp when last valid bell was started (for spacing validation)
  final int _bellThreshold =
      400; // Amplitude threshold for bell detection (lowered to catch all frequencies in top frequencies)
  StreamSubscription? _audioStream;
  String _status = '';
  Timer? _audioPollingTimer;
  String? _recordingPath;
  int _lastProcessedBytes = 0;
  bool _wavHeaderSkipped =
      false; // Track if we've skipped the 44-byte WAV header

  // FFT-based detection fields
  // Bell frequencies from calibration (12 distinct peaks in bell spectrum)
  final List<double> _bellSpectrumPeaks = [
    7022.0,
    6150.0,
    5344.0,
    4561.0,
    3865.0,
    3609.0,
    3166.0,
    2591.0,
    2588.0,
    2036.0,
    1509.0,
    1016.0,
  ];
  final int _topNFrequencies =
      5; // Only 5 top frequencies - at least one bell frequency should be here
  final List<double> _noiseBaseline =
      []; // Recent noise levels for dynamic thresholding
  final int _noiseBaselineWindow =
      20; // Number of samples to average for noise floor
  final double _bellFrequencyDetectionThreshold =
      0.50; // Require ~50% of frequencies (6 out of 12)

  int _maxTimestampProcessed = 0;

  // Audio chunk buffering for out-of-order chunk handling
  final List<_AudioChunkData> _chunkBuffer = [];
  static const int _maxChunkBufferSize = 4;

  @override
  void initState() {
    super.initState();
    // Only initialize recorder on mobile platforms
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _recorder = AudioRecorder();
    }
  }

  @override
  void dispose() {
    _audioPollingTimer?.cancel();
    _stopMicrophoneListener();
    _recorder?.dispose();
    super.dispose();
  }

  double _calculateAudioCorrelation(Uint8List chunk, int audioStreamMs) {
    // Compute FFT for the incoming chunk using hardcoded bell frequencies
    final chunkSpectrum = _computeFFT(chunk);

    if (chunkSpectrum.isEmpty || _bellSpectrumPeaks.isEmpty) {
      return 0.0;
    }

    // Calculate correlation between incoming audio and calibrated bell peak frequencies
    return _calculateFrequencyCorrelation(chunkSpectrum, audioStreamMs);
  }

  /// Compute FFT spectrum from audio data
  List<double> _computeFFT(Uint8List audioData) {
    try {
      // Extract 16-bit PCM samples
      final samples = <double>[];
      final buffer = ByteData.view(audioData.buffer);

      for (int i = 0; i < (audioData.length ~/ 2); i++) {
        final sample = buffer.getInt16(i * 2, Endian.little).toDouble();
        samples.add(sample);
      }

      if (samples.isEmpty) {
        return [];
      }

      // Use power-of-2 FFT size appropriate for sample count
      // For 20ms @ 16kHz = 320 samples, use 512
      // For 100ms @ 16kHz = 1600 samples, use 2048
      // For 400ms @ 16kHz = 6400 samples, use 8192 (bell peal duration)
      int fftSize = 256;
      while (fftSize < samples.length && fftSize < 8192) {
        fftSize *= 2;
      }

      // Use up to 8192 for better frequency resolution
      if (fftSize > 8192) {
        fftSize = 8192;
      }

      // Pad with zeros to reach fftSize
      while (samples.length < fftSize) {
        samples.add(0.0);
      }

      // Apply Hann window to reduce spectral leakage
      final windowed = <double>[];
      for (int i = 0; i < fftSize; i++) {
        final window = 0.5 - 0.5 * cos(2 * pi * i / (fftSize - 1));
        windowed.add(samples[i] * window);
      }

      // Compute FFT using the fft package
      final spectrum = FFT.Transform(windowed);

      // Convert complex spectrum to magnitude
      final magnitude = <double>[];
      for (final complex in spectrum) {
        final mag = sqrt(
          complex.real * complex.real + complex.imaginary * complex.imaginary,
        );
        magnitude.add(mag);
      }

      return magnitude;
    } catch (e) {
      _debugLog('❌ FFT computation error: $e');
      return [];
    }
  }

  /// Calculate correlation between incoming audio and bell sample frequencies
  double _calculateFrequencyCorrelation(
    List<double> incomingSpectrum,
    int audioStreamMs,
  ) {
    if (_bellSpectrumPeaks.isEmpty || incomingSpectrum.isEmpty) {
      return 0.0;
    }

    final sampleRate = 16000; // Hz
    final freqResolution = sampleRate / incomingSpectrum.length;

    // Apply low-pass filter: zero out frequencies above 8000Hz to reduce noise
    // Keeps all bell frequencies (up to 7022Hz) while filtering out high-frequency noise
    final cutoffFreq = 8000.0; // Hz
    final cutoffBin = (cutoffFreq / freqResolution).toInt();
    final filteredSpectrum = List<double>.from(incomingSpectrum);
    for (int i = cutoffBin; i < filteredSpectrum.length; i++) {
      filteredSpectrum[i] = 0.0;
    }

    // Find the top N frequencies by magnitude (only in 1000-8000 Hz range to ignore low-freq rumble)
    final double minFreq = 1000.0;
    final double maxFreq = 8000.0;
    final List<MapEntry<int, double>> frequencyMagnitudes = [];
    for (int i = 0; i < filteredSpectrum.length; i++) {
      final freq = i * freqResolution;
      if (freq >= minFreq && freq <= maxFreq) {
        frequencyMagnitudes.add(MapEntry(i, filteredSpectrum[i]));
      }
    }
    frequencyMagnitudes.sort((a, b) => b.value.compareTo(a.value));
    final topNBins = frequencyMagnitudes
        .take(_topNFrequencies)
        .map((e) => e.key)
        .toSet();

    // Check how many bell peak frequencies are present in incoming audio
    int matchingPeaks = 0;
    int bellPeaksInTopN = 0;
    final peakDetails = <String>[];
    final requiredMatches =
        ((_bellSpectrumPeaks.length * _bellFrequencyDetectionThreshold).ceil());

    for (final bellFreq in _bellSpectrumPeaks) {
      final binIndex = (bellFreq / freqResolution).toInt();

      // Check a range around the expected frequency (±3% tolerance)
      final frequencyTolerance = bellFreq * 0.03; // 3% variation allowed
      final searchRangeBins = (frequencyTolerance / freqResolution)
          .toInt()
          .clamp(1, 5);
      double maxMagnitude = 0;
      int maxBinInRange = binIndex;

      for (
        int i = (binIndex - searchRangeBins).clamp(
          0,
          filteredSpectrum.length - 1,
        );
        i <= (binIndex + searchRangeBins).clamp(0, filteredSpectrum.length - 1);
        i++
      ) {
        if (filteredSpectrum[i] > maxMagnitude) {
          maxMagnitude = filteredSpectrum[i];
          maxBinInRange = i;
        }
      }

      // If energy is strong at this frequency, count it as a match
      if (maxMagnitude > _bellThreshold) {
        // Magnitude threshold - bell peaks are 23000-36000, background noise is much lower
        matchingPeaks++;

        // Calculate actual frequency of the peak we found
        final actualFreq = maxBinInRange * freqResolution;
        final frequencyError = (actualFreq - bellFreq).abs();

        // Also check if this peak is in the top N frequencies AND matches our target frequency closely
        if (topNBins.contains(maxBinInRange) &&
            frequencyError < (bellFreq * 0.03)) {
          bellPeaksInTopN++;
          peakDetails.add(
            '✓ ${bellFreq.toStringAsFixed(0)}Hz: ${maxMagnitude.toStringAsFixed(0)}',
          );
        } else {
          peakDetails.add(
            '⚠ ${bellFreq.toStringAsFixed(0)}Hz: ${maxMagnitude.toStringAsFixed(0)}',
          );
        }
      } else {
        peakDetails.add(
          '✗ ${bellFreq.toStringAsFixed(0)}Hz: ${maxMagnitude.toStringAsFixed(0)}',
        );
      }
    }

    // Return correlation if:
    // 1. At least one bell frequency is in the top 5 (1000-8000 Hz range)
    // 2. At least 75% of frequencies meet the threshold
    final minInTopN = 1;
    final correlation =
        (bellPeaksInTopN >= minInTopN && matchingPeaks >= requiredMatches)
        ? 1.0
        : 0.0;

    _debugLog(
      '$audioStreamMs ${correlation == 1.0 ? '✅' : '❌'} ($matchingPeaks/$requiredMatches): ${peakDetails.join(' ')}',
    );

    // Add to noise baseline for dynamic thresholding
    _noiseBaseline.add(
      filteredSpectrum.isNotEmpty
          ? filteredSpectrum.reduce((a, b) => a + b)
          : 0,
    );
    if (_noiseBaseline.length > _noiseBaselineWindow) {
      _noiseBaseline.removeAt(0);
    }

    return correlation;
  }

  Future<void> _requestMicrophonePermission() async {
    _debugLog('🔐 Requesting microphone permission...');
    final status = await Permission.microphone.request();
    _debugLog('🔐 Permission status: $status');
    if (!mounted) return;

    if (status.isDenied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission denied')),
      );
    }
  }

  Future<void> _toggleMicrophoneListener() async {
    _debugLog('📱 Toggle microphone listener called');
    if (_recorder == null) {
      _debugLog('❌ Recorder is null!');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Microphone not available on this platform'),
        ),
      );
      return;
    }

    if (_isListeningToMic) {
      _debugLog('🛑 Stopping microphone listener');
      _stopMicrophoneListener();
    } else {
      _debugLog('▶️ Starting microphone listener');
      await _startMicrophoneListener();
    }
  }

  Future<void> _startMicrophoneListener() async {
    _debugLog('▶️ _startMicrophoneListener called');
    if (_recorder == null) {
      _debugLog('❌ Recorder is null in _startMicrophoneListener!');
      if (mounted) {
        setState(() {
          _status = 'Microphone not available on this platform';
        });
      }
      return;
    }

    _debugLog('📡 Starting audio recording to file...');
    try {
      // Get app temp directory for recording file
      final tempDir = Directory.systemTemp;
      _recordingPath = '${tempDir.path}/audio_recording.wav';
      _debugLog('📁 Recording path: $_recordingPath');

      await _recorder!.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          numChannels: 1,
          sampleRate: 16000,
        ),
        path: _recordingPath!,
      );
      _debugLog('✅ Audio recording started successfully');

      _lastProcessedBytes = 0;
      _wavHeaderSkipped = false; // Reset header skip flag for new recording
      _bellDetectionStartTime = null;
      _suppressingForBell = false;
      _suppressionEndTime = null;
      _lastValidBellStartTime = null;
      _bellCount = 0;
      _bellPatternTimes.clear();
      _bellPeakTimes.clear();

      if (!mounted) return;
      setState(() {
        _isListeningToMic = true;
        _status = 'Listening for bells...';
      });

      _debugLog('🎤 Microphone recording started - polling file for audio...');

      // Poll the recording file every 20ms for more granular detection
      _audioPollingTimer = Timer.periodic(const Duration(milliseconds: 20), (
        timer,
      ) {
        if (_recordingPath == null) {
          _debugLog('❌ Recording path is null, stopping polling');
          timer.cancel();
          return;
        }

        final file = File(_recordingPath!);
        if (!file.existsSync()) {
          _debugLog('❌ Recording file does not exist, stopping polling');
          timer.cancel();
          return;
        }

        final fileSize = file.lengthSync();

        // On first read, skip to most recent audio (skip old data from buffer)
        // Keep last 500ms = 16000 samples * 2 bytes = 16000 bytes
        if (_lastProcessedBytes == 0 && fileSize > 16000 + 44) {
          _debugLog(
            '⏭️  First read: skipping old data, jumping to recent audio',
          );
          _lastProcessedBytes = (fileSize - 16000).clamp(44, fileSize);
          _debugLog(
            '    Setting _lastProcessedBytes to $_lastProcessedBytes (header at byte 44)',
          );
        }

        if (fileSize > _lastProcessedBytes) {
          try {
            final file = File(_recordingPath!);
            final bytes = file.readAsBytesSync();
            var newBytes = bytes.sublist(_lastProcessedBytes);

            // Skip WAV header (44 bytes) on very first read if we haven't skipped it yet
            if (!_wavHeaderSkipped && _lastProcessedBytes < 44) {
              newBytes = Uint8List.fromList(newBytes.sublist(44));
              _wavHeaderSkipped = true;
            } else if (!_wavHeaderSkipped) {
              // We jumped past the header already
              _wavHeaderSkipped = true;
            }

            // Process in small chunks to avoid UI freeze
            // 240 samples * 2 bytes = 480 byte chunks max (30ms @ 16kHz)
            const int maxChunkSize = 480;
            int processedThisRound = 0;

            while (processedThisRound < newBytes.length) {
              int chunkEnd = (processedThisRound + maxChunkSize).clamp(
                0,
                newBytes.length,
              );
              final chunk = Uint8List.fromList(
                newBytes.sublist(processedThisRound, chunkEnd),
              );
              final chunkSize = chunkEnd - processedThisRound;
              final byteOffset = _lastProcessedBytes + processedThisRound;
              final audioStreamMs = ((byteOffset - 44) / 32000 * 1000).toInt();

              if (chunk.isNotEmpty) {
                // Add to buffer instead of processing immediately
                _chunkBuffer.add(
                  _AudioChunkData(chunk, byteOffset, audioStreamMs),
                );
              }

              _lastProcessedBytes += chunkSize;
              processedThisRound = chunkEnd;
            }
            _processBufferedChunks();

            _lastProcessedBytes = fileSize;
          } catch (e) {
            _debugLog('❌ Error reading recording file: $e');
            timer.cancel();
          }
        }
      });
    } catch (e) {
      _debugLog('❌ Exception starting microphone: $e');
      if (mounted) {
        setState(() {
          _status = 'Error: $e';
        });
      }
    }
  }

  void _stopMicrophoneListener() async {
    if (_recorder == null) return;

    _debugLog('🛑 Stopping microphone listener');
    _audioPollingTimer?.cancel();
    await _recorder!.stop();
    _audioStream?.cancel();

    // Clean up recording file
    if (_recordingPath != null) {
      try {
        final file = File(_recordingPath!);
        if (file.existsSync()) {
          file.deleteSync();
          _debugLog('🗑️ Deleted recording file');
        }
      } catch (e) {
        _debugLog('⚠️ Could not delete recording file: $e');
      }
    }

    // Reset state for next listening session
    _bellCount = 0;
    _bellPatternTimes.clear();
    _bellPeakTimes.clear();
    _bellDetectionStartTime = null;
    _suppressingForBell = false;
    _suppressionEndTime = null;
    _lastValidBellStartTime = null;
    _chunkBuffer.clear();
    _maxTimestampProcessed = 0;

    if (mounted) {
      setState(() {
        _isListeningToMic = false;
        _status = '';
      });
    }
  }

  void _processBufferedChunks() {
    if (_chunkBuffer.isEmpty) {
      _debugLog('⚠️ Buffer empty, nothing to process');
      return;
    }

    // Sort buffer by timestamp and process oldest first
    _chunkBuffer.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Process chunks only when buffer exceeds max size
    // This gives us a chance to reorder out-of-order chunks before committing
    while (_chunkBuffer.length > _maxChunkBufferSize) {
      try {
        final chunkData = _chunkBuffer.removeAt(0);
        _processAudioChunk(chunkData.chunk, chunkData.byteOffset);
      } catch (e) {
        _debugLog('❌ Exception in _processAudioChunk: $e');
      }
    }
  }

  void _processAudioChunk(Uint8List chunk, int byteOffset) {
    final audioStreamMs = ((byteOffset - 44) / 32000 * 1000).toInt();
    final now = audioStreamMs;

    // Skip out-of-order chunks
    if (now < _maxTimestampProcessed) {
      _debugLog(
        '⚠️  Ignoring out-of-order chunk: $now < $_maxTimestampProcessed',
      );
      return;
    }
    _maxTimestampProcessed = now;

    // If we're suppressing after detecting a bell start, check if bell is finished
    if (_suppressingForBell) {
      if (_bellDetectionStartTime != null &&
          now - _bellDetectionStartTime! >= 399) {
        _suppressingForBell =
            false; // Done suppressing, back to normal processing
        _suppressionEndTime = now; // Mark when suppression ended
      } else {
        _debugLog('$now ➖ skipped');
        return; // Still in suppression window, skip this chunk (and correlation calculation)
      }
    }

    // Check if we've exceeded 300ms without detecting a bell end - reset if timeout
    if (_suppressionEndTime != null && now - _suppressionEndTime! > 300) {
      _debugLog(
        '❌ Timeout: no bell end detected within 300ms, resetting to initial state',
      );
      _bellDetectionStartTime = null;
      _suppressionEndTime = null;
      _bellCount = 0;
      _bellPatternTimes.clear();
      _lastValidBellStartTime = null;
    }

    // Now calculate correlation only if we're not suppressing
    final correlation = _calculateAudioCorrelation(chunk, now);

    // For FFT correlation, we need 75%+ of frequencies to match
    final fftCorrelationThreshold = 1.0;
    final isMatch = correlation >= fftCorrelationThreshold;

    // Track positive detections for statistics
    if (isMatch) {
      _bellPeakTimes.add(now);
      // Keep only recent detections (within last 2 seconds)
      if (_bellPeakTimes.isNotEmpty && now - _bellPeakTimes.first > 2000) {
        _bellPeakTimes.removeAt(0);
      }
    }

    // Detect bell start: positive correlation when not currently detecting a bell
    if (isMatch && _bellDetectionStartTime == null) {
      final bellNumber = _bellCount + 1;

      // Check timing with previous bell (for bells after the first one)
      bool timingOk = false;
      if (_lastValidBellStartTime == null) {
        timingOk = true; // First bell, always valid
        _debugLog('🔔 Bell $bellNumber detected');
      } else {
        final timeSinceLast = now - _lastValidBellStartTime!;
        const expectedMs = 400; // 0.4 seconds
        const toleranceMs = 100; // ±100ms
        timingOk =
            (timeSinceLast >= expectedMs - toleranceMs) &&
            (timeSinceLast <= expectedMs + toleranceMs);
        _debugLog(
          '🔔 Bell $bellNumber detected - spacing: ${timeSinceLast}ms (expected ${expectedMs}±${toleranceMs}ms) - ${timingOk ? '✅' : '❌'}',
        );
      }

      if (timingOk) {
        // Valid bell start detected, increment count and start suppression
        _bellCount++;
        _lastValidBellStartTime = now; // Record this valid bell's start time
        _bellDetectionStartTime = now;
        _suppressingForBell = true;
        _suppressionEndTime = null; // Clear any previous timeout tracker

        if (mounted) {
          setState(() {
            _status = 'Bells detected: $_bellCount/3';
          });
        }

        // Check if we've detected 3 bells
        if (_bellCount == 3) {
          _onThreeBellsDetected();
          _bellCount = 0;
          _bellPatternTimes.clear();
          _bellPeakTimes.clear();
          _lastValidBellStartTime = null;
          _bellDetectionStartTime = null;
          _suppressionEndTime = null;
          return; // Exit early to avoid further processing
        }
      } else {
        // Timing not valid, reset to initial state
        _debugLog('❌ Bell timing not correct');
        _bellCount = 0;
        _bellPatternTimes.clear();
        _lastValidBellStartTime = null;
        _suppressionEndTime = null;
        return; // Don't start suppression if timing is invalid
      }

      return; // Suppress further processing while bell ringing
    }

    // Detect bell end: negative correlation after suppression has ended
    if (!isMatch && _bellDetectionStartTime != null && !_suppressingForBell) {
      // Just mark that the bell has ended, reset detection
      _bellDetectionStartTime = null;
    }
  }

  void _onThreeBellsDetected() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔔 Three bells detected!'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    // Stop listening
    _stopMicrophoneListener();

    // Navigate to timer page and clear color when returning
    if (mounted) {
      Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (context) => TimerPage(myColor: _myColor),
            ),
          )
          .then((_) {
            if (mounted) {
              setState(() {
                _myColor = null;
              });
            }
          });
    }
  }

  void _toggleTimer() {
    // Stop listening if active
    if (_isListeningToMic) {
      _stopMicrophoneListener();
    }

    Navigator.of(context)
        .push(
          MaterialPageRoute(builder: (context) => TimerPage(myColor: _myColor)),
        )
        .then((_) {
          if (mounted) {
            setState(() {
              _myColor = null;
            });
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.grey.shade900,
        foregroundColor: Colors.white,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_status.isNotEmpty)
              Column(
                children: [
                  Text(
                    _status,
                    style: const TextStyle(fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            const Text('What color am I?'),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _myColor = 'red';
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _myColor == 'red' ? Colors.red : null,
                  ),
                  child: Text(
                    'Red',
                    style: TextStyle(
                      color: _myColor == 'red' ? Colors.white : null,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _myColor = 'blue';
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _myColor == 'blue' ? Colors.blue : null,
                  ),
                  child: Text(
                    'Blue',
                    style: TextStyle(
                      color: _myColor == 'blue' ? Colors.white : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_recorder != null)
              ElevatedButton(
                onPressed: () {
                  _requestMicrophonePermission();
                  _toggleMicrophoneListener();
                },
                child: Text(
                  _isListeningToMic
                      ? 'Stop Listening'
                      : 'Listen for Teleop Bells',
                ),
              ),
            if (_recorder != null) const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                _toggleTimer();
              },
              child: const Text('Start Teleop'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioChunkData {
  final Uint8List chunk;
  final int byteOffset;
  final int timestamp;

  _AudioChunkData(this.chunk, this.byteOffset, this.timestamp);
}

class TimerPage extends StatefulWidget {
  const TimerPage({super.key, this.myColor});
  final String? myColor;

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  int _counter = 0;
  late Timer _timer;
  String? _autoWinner; // Track which team won auto: 'red' or 'blue'
  late DateTime _matchEndTime;

  // Transition times in seconds: 2:10, 1:45, 1:20, 0:55, 0:30, 0:00
  final List<int> _transitionTimes = [130, 105, 80, 55, 30, 0];
  final List<String> _transitionActives = [
    'both',
    'loser',
    'winner',
    'loser',
    'winner',
    'both',
  ];

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    if (_counter != 0) {
      _timer.cancel();
    }
    super.dispose();
  }

  void _startTimer() {
    _matchEndTime = DateTime.now().add(const Duration(milliseconds: 139300));
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      setState(() {
        final now = DateTime.now();
        final millisecondsRemaining = _matchEndTime
            .difference(now)
            .inMilliseconds;
        _counter = max(0, (millisecondsRemaining / 1000).ceil());

        if (_counter <= 0) {
          _counter = 0;
          _timer.cancel();
          _goHome();
        }
      });
    });
  }

  void _goHome() {
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  String _formatTime(int seconds) {
    int minutes = seconds ~/ 60;
    int secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  int _getSecondsUntilNextTransition() {
    // Find the next transition time that is less than current counter
    for (final transitionTime in _transitionTimes) {
      if (_counter > transitionTime) {
        return _counter - transitionTime;
      }
    }
    // If we've passed all transitions, return 0
    return 0;
  }

  Color _getTransitionBackgroundColor() {
    // Find which transition we're currently in
    int transitionIndex = -1;
    for (int i = 0; i < _transitionTimes.length; i++) {
      if (_counter > _transitionTimes[i]) {
        transitionIndex = i;
        break;
      }
    }

    if (transitionIndex == -1 || transitionIndex >= _transitionActives.length) {
      return Colors.grey.shade800;
    }

    final activeState = _transitionActives[transitionIndex];

    if (activeState == 'both') {
      return Colors.purple.shade700;
    }

    // If neither team won auto yet, show dark gray
    if (_autoWinner == null) {
      return Colors.grey.shade800;
    }

    // Determine if we're showing the winner or loser
    if (activeState == 'winner') {
      return _autoWinner == 'red' ? Colors.red.shade700 : Colors.blue.shade700;
    } else if (activeState == 'loser') {
      return _autoWinner == 'red' ? Colors.blue.shade700 : Colors.red.shade700;
    }

    return Colors.grey.shade800;
  }

  String _getTransitionLabel() {
    // Find which transition we're currently in
    int transitionIndex = -1;
    for (int i = 0; i < _transitionTimes.length; i++) {
      if (_counter > _transitionTimes[i]) {
        transitionIndex = i;
        break;
      }
    }

    if (transitionIndex == -1 || transitionIndex >= _transitionActives.length) {
      return 'Active hub: both';
    }

    final activeState = _transitionActives[transitionIndex];

    if (activeState == 'both') {
      return 'Active hub: both';
    }

    // If autoWinner is not set, show generic label
    if (_autoWinner == null) {
      return activeState == 'winner'
          ? 'Active hub: auto winner'
          : 'Active hub: auto loser';
    }

    // If autoWinner is set, show the actual color
    if (activeState == 'winner') {
      return _autoWinner == 'red' ? 'Active hub: red' : 'Active hub: blue';
    } else {
      return _autoWinner == 'red' ? 'Active hub: blue' : 'Active hub: red';
    }
  }

  bool _shouldHighlightPageBackground() {
    // Find which transition we're currently in
    int transitionIndex = -1;
    for (int i = 0; i < _transitionTimes.length; i++) {
      if (_counter > _transitionTimes[i]) {
        transitionIndex = i;
        break;
      }
    }

    if (transitionIndex == -1 || transitionIndex >= _transitionActives.length) {
      return false;
    }

    final activeState = _transitionActives[transitionIndex];

    // Highlight if transition is 'both'
    if (activeState == 'both') {
      return true;
    }

    // Highlight if my color matches the transition color being displayed
    if (widget.myColor == null || _autoWinner == null) {
      return false;
    }

    // Determine what color the transition is showing and compare to my color
    final transitionColor = activeState == 'winner'
        ? (_autoWinner == 'red' ? 'red' : 'blue')
        : (_autoWinner == 'red' ? 'blue' : 'red');

    return widget.myColor == transitionColor;
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    final leftColumn = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text('Who won auto?'),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _autoWinner = 'red';
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _autoWinner == 'red' ? Colors.red : null,
              ),
              child: Text(
                'Red',
                style: TextStyle(
                  color: _autoWinner == 'red' ? Colors.white : null,
                ),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _autoWinner = 'blue';
                });
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _autoWinner == 'blue' ? Colors.blue : null,
              ),
              child: Text(
                'Blue',
                style: TextStyle(
                  color: _autoWinner == 'blue' ? Colors.white : null,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
        const Text('Match time'),
        Text(
          _formatTime(_counter),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
      ],
    );

    final rightColumn = Container(
      color: _getTransitionBackgroundColor(),
      padding: EdgeInsets.all(MediaQuery.of(context).size.height * 0.05),
      width: MediaQuery.of(context).size.shortestSide * 0.8,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _getTransitionLabel(),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 20),
          Builder(
            builder: (context) {
              final fontSize = MediaQuery.of(context).size.shortestSide * 0.4;
              final boxHeight = fontSize * 1.2;
              final boxWidth = fontSize * 1.8; // Wide enough for 2 digits
              return SizedBox(
                width: boxWidth,
                height: boxHeight,
                child: Center(
                  child: Text(
                    '${_getSecondsUntilNextTransition()}',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.bold,
                      height: 1.0,
                      color: Colors.white,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.grey.shade900,
        foregroundColor: Colors.white,
        title: const Text('Match Timer'),
      ),
      body: Container(
        color: _shouldHighlightPageBackground()
            ? Colors.yellow
            : Colors.transparent,
        child: Center(
          child: isLandscape
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [leftColumn, rightColumn],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    leftColumn,
                    const SizedBox(height: 30),
                    rightColumn,
                  ],
                ),
        ),
      ),
    );
  }
}
