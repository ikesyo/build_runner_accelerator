import 'package:build/build.dart';

int _nextResourceId = 0;

final Resource<_ResourceState> _sharedResource = Resource<_ResourceState>(
  () => _ResourceState(++_nextResourceId),
);

Builder lifetimeBuilder(BuilderOptions options) => _LifetimeBuilder();

class _ResourceState {
  _ResourceState(this.id);

  final int id;
  int uses = 0;
}

class _LifetimeBuilder implements Builder {
  static int _nextInstanceId = 0;

  _LifetimeBuilder() : instanceId = ++_nextInstanceId;

  final int instanceId;
  int buildCount = 0;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.txt': <String>['.lifetime.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final resource = await buildStep.fetchResource(_sharedResource);
    final buildNumber = ++buildCount;
    final resourceUse = ++resource.uses;
    final output = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst(RegExp(r'\.txt$'), '.lifetime.txt'),
    );
    await buildStep.writeAsString(
      output,
      'input=${buildStep.inputId.path} '
      'instance=$instanceId '
      'build=$buildNumber '
      'resource=${resource.id} '
      'resource_use=$resourceUse\n',
    );
  }
}
