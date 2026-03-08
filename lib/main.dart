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
  final int _bellDetectionWindow = 1000; // 1 second window

  // State machine for bell pattern detection
  // Expected pattern: matching → not-matching → matching → not-matching → matching
  final List<bool> _expectedBellPattern = [true, false, true, false, true];
  final List<bool> _currentBellPattern = [];
  final List<int> _bellPatternTimes =
      []; // timestamps of each pattern transition
  bool _lastChunkWasMatch = false;
  final int _bellThreshold =
      8000; // Amplitude threshold for bell detection (adjustable for debugging)
  StreamSubscription? _audioStream;
  String _status = '';
  Timer? _audioPollingTimer;
  String? _recordingPath;
  int _lastProcessedBytes = 0;
  bool _wavHeaderSkipped =
      false; // Track if we've skipped the 44-byte WAV header

  // FFT-based detection fields
  // Default bell frequencies from calibration: 1016Hz, 2000Hz, 1492Hz
  final List<double> _bellSpectrumPeaks = [1016.0, 2000.0, 1492.0];
  final List<double> _noiseBaseline =
      []; // Recent noise levels for dynamic thresholding
  final int _noiseBaselineWindow =
      20; // Number of samples to average for noise floor

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

  double _calculateAudioCorrelation(Uint8List chunk) {
    // Compute FFT for the incoming chunk using hardcoded bell frequencies
    final chunkSpectrum = _computeFFT(chunk);

    if (chunkSpectrum.isEmpty || _bellSpectrumPeaks.isEmpty) {
      return 0.0;
    }

    // Calculate correlation between incoming audio and calibrated bell peak frequencies
    return _calculateFrequencyCorrelation(chunkSpectrum);
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
      int fftSize = 256;
      while (fftSize < samples.length && fftSize < 2048) {
        fftSize *= 2;
      }

      // Don't exceed 2048 for performance
      if (fftSize > 2048) {
        fftSize = 2048;
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
  double _calculateFrequencyCorrelation(List<double> incomingSpectrum) {
    if (_bellSpectrumPeaks.isEmpty || incomingSpectrum.isEmpty) {
      return 0.0;
    }

    final sampleRate = 16000; // Hz
    final freqResolution = sampleRate / incomingSpectrum.length;

    // Check how many bell peak frequencies are present in incoming audio
    int matchingPeaks = 0;
    final peakDetails = <String>[];

    for (final bellFreq in _bellSpectrumPeaks) {
      final binIndex = (bellFreq / freqResolution).toInt();

      // Check a range around the expected frequency
      final searchRange = 3; // bins
      double maxMagnitude = 0;

      for (
        int i = (binIndex - searchRange).clamp(0, incomingSpectrum.length - 1);
        i <= (binIndex + searchRange).clamp(0, incomingSpectrum.length - 1);
        i++
      ) {
        if (incomingSpectrum[i] > maxMagnitude) {
          maxMagnitude = incomingSpectrum[i];
        }
      }

      // If energy is strong at this frequency, count it as a match
      if (maxMagnitude > _bellThreshold) {
        // Magnitude threshold - bell peaks are 23000-36000, background noise is much lower
        matchingPeaks++;
        peakDetails.add(
          '✓ ${bellFreq.toStringAsFixed(0)}Hz: ${maxMagnitude.toStringAsFixed(0)}',
        );
      } else {
        peakDetails.add(
          '✗ ${bellFreq.toStringAsFixed(0)}Hz: ${maxMagnitude.toStringAsFixed(0)} (threshold: $_bellThreshold)',
        );
      }
    }

    // Return correlation as ratio of matched peaks
    final correlation = matchingPeaks / _bellSpectrumPeaks.length;
    _debugLog(
      '📊 Frequency correlation: ${correlation.toStringAsFixed(2)} ($matchingPeaks/${_bellSpectrumPeaks.length} peaks matched)',
    );
    for (final detail in peakDetails) {
      _debugLog('   $detail');
    }

    // Add to noise baseline for dynamic thresholding
    _noiseBaseline.add(
      incomingSpectrum.isNotEmpty
          ? incomingSpectrum.reduce((a, b) => a + b)
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
            // 2048 samples * 2 bytes = 4096 byte chunks max
            const int maxChunkSize = 4096;
            int processedThisRound = 0;

            while (processedThisRound < newBytes.length) {
              int chunkEnd = (processedThisRound + maxChunkSize).clamp(
                0,
                newBytes.length,
              );
              final chunk = Uint8List.fromList(
                newBytes.sublist(processedThisRound, chunkEnd),
              );

              if (chunk.isNotEmpty) {
                try {
                  _processAudioChunk(chunk);
                } catch (e) {
                  _debugLog('❌ Exception in _processAudioChunk: $e');
                }
              }

              processedThisRound = chunkEnd;

              // If we have more data, update position but don't read again this cycle
              if (processedThisRound < newBytes.length) {
                _lastProcessedBytes += (chunkEnd - 0);
              }
            }

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

    if (mounted) {
      setState(() {
        _isListeningToMic = false;
        _status = '';
      });
    }
  }

  void _processAudioChunk(Uint8List chunk) {
    // Calculate how similar this chunk's frequency spectrum is to the calibrated bell peak frequencies
    final correlation = _calculateAudioCorrelation(chunk);

    // For FFT correlation, we need ALL bell peaks to match (100%)
    // This is more robust than time-domain correlation
    final fftCorrelationThreshold = 1.0;
    final isMatch = correlation >= fftCorrelationThreshold;
    final now = DateTime.now().millisecondsSinceEpoch;

    // State machine: track pattern changes (match to non-match and vice versa)
    if (isMatch != _lastChunkWasMatch) {
      // State changed - record this transition
      _currentBellPattern.add(isMatch);
      _bellPatternTimes.add(now);
      _lastChunkWasMatch = isMatch;
      _debugLog(
        '   📊 Pattern transition: ${isMatch ? '✓' : '✗'} (pattern length: ${_currentBellPattern.length})',
      );

      if (mounted) {
        setState(() {
          _status =
              'Pattern: ${_currentBellPattern.map((m) => m ? '✓' : '✗').join(' ')} (need: ✓ ✗ ✓ ✗ ✓)';
        });
      }

      // Check if pattern is outside the 1-second window
      if (_bellPatternTimes.isNotEmpty &&
          now - _bellPatternTimes.first > _bellDetectionWindow) {
        _currentBellPattern.clear();
        _bellPatternTimes.clear();
        _lastChunkWasMatch = isMatch;
        _currentBellPattern.add(isMatch);
        _bellPatternTimes.add(now);
      }

      // Check if we've matched the expected pattern (at exactly 5 transitions or if we have at least 5)
      if (_currentBellPattern.length >= _expectedBellPattern.length) {
        // Check if the last 5 transitions match the expected pattern
        bool patternMatches = true;
        for (int i = 0; i < _expectedBellPattern.length; i++) {
          int checkIndex =
              _currentBellPattern.length - _expectedBellPattern.length + i;
          if (_currentBellPattern[checkIndex] != _expectedBellPattern[i]) {
            patternMatches = false;
            break;
          }
        }

        if (patternMatches) {
          _onThreeBellsDetected();
          _currentBellPattern.clear();
          _bellPatternTimes.clear();
          _lastChunkWasMatch = false;
          return; // Exit early to avoid further processing
        }
      }
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

class TimerPage extends StatefulWidget {
  const TimerPage({super.key, this.myColor});
  final String? myColor;

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  int _counter = 139;
  late Timer _timer;
  bool _isRunning = true;
  String? _autoWinner; // Track which team won auto: 'red' or 'blue'

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
    if (_isRunning) {
      _timer.cancel();
    }
    super.dispose();
  }

  void _startTimer() {
    _isRunning = true;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _counter--;
        if (_counter <= 0) {
          _counter = 0;
          _timer.cancel();
          _isRunning = false;
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
      padding: EdgeInsets.all(MediaQuery.of(context).size.height * 0.1),
      width: MediaQuery.of(context).size.shortestSide * 0.8,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Transition', style: TextStyle(color: Colors.white)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${_getSecondsUntilNextTransition()}',
                textAlign: TextAlign.center,
                maxLines: 1,
                style: TextStyle(
                  fontSize: MediaQuery.of(context).size.shortestSide * 0.5,
                  fontWeight: FontWeight.bold,
                  height: 0.8,
                  color: Colors.white,
                ),
              ),
            ),
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
