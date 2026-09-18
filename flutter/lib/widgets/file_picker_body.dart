import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:theme/theme.dart';

/// A picked file plus its resolved size, since `PlatformFile.length()` in
/// the pinned `file_picker`/`cross_file` version is async (an `XFile`
/// method) and can't be read synchronously from list-building code.
class _PickedFile {
  final PlatformFile file;
  final int sizeBytes;
  const _PickedFile(this.file, this.sizeBytes);
}

/// Body-only (no `Scaffold`/`AppBar`) file-selection UI, extracted from
/// the old `file_picker_screen.dart` for reuse as one step of the Home
/// tab's Send flow. [onContinue] is invoked with the resolved absolute
/// file paths once the user taps Continue.
class FilePickerBody extends StatefulWidget {
  const FilePickerBody({super.key, required this.onContinue});

  final ValueChanged<List<String>> onContinue;

  @override
  State<FilePickerBody> createState() => _FilePickerBodyState();
}

class _FilePickerBodyState extends State<FilePickerBody> {
  final List<_PickedFile> _selected = [];

  int get _totalBytes => _selected.fold<int>(0, (sum, f) => sum + f.sizeBytes);

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles();

    final additions = <_PickedFile>[];
    for (final file in files) {
      if (_selected.any((f) => f.file.path == file.path)) continue;
      final size = await file.xFile.length();
      additions.add(_PickedFile(file, size));
    }
    if (!mounted) return;
    setState(() => _selected.addAll(additions));
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('Select Files', style: AppTypography.titleLarge),
              ),
              IconButton(icon: const Icon(Icons.add), tooltip: 'Add files', onPressed: _pickFiles),
            ],
          ),
        ),
        Expanded(
          child: _selected.isEmpty
              ? Center(
                  child: ThemeEmptyState(
                    icon: Icons.file_present_outlined,
                    title: 'No files selected',
                    subtitle: 'Pick one or more files from this device to send.',
                    actionLabel: 'Browse files',
                    onAction: _pickFiles,
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _selected.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final picked = _selected[index];
                    return ThemeCard(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text(picked.file.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_formatBytes(picked.sizeBytes)),
                        trailing: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _selected.removeAt(index)),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_selected.isNotEmpty)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_selected.length} file${_selected.length == 1 ? '' : 's'} selected '
                      '(${_formatBytes(_totalBytes)})',
                      style: AppTypography.bodyMedium,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () =>
                        widget.onContinue(_selected.map((f) => f.file.path!).toList()),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Continue'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
