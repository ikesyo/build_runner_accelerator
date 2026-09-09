import 'package:json_annotation/json_annotation.dart';

part 'model_224.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model224 {
  const Model224({required this.id, required this.value});

  final int id;
  final String value;

  factory Model224.fromJson(Map<String, dynamic> json) =>
      _$Model224FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model224ToJson(this);
}
