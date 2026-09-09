import 'package:json_annotation/json_annotation.dart';

part 'model_384.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model384 {
  const Model384({required this.id, required this.value});

  final int id;
  final String value;

  factory Model384.fromJson(Map<String, dynamic> json) =>
      _$Model384FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model384ToJson(this);
}
