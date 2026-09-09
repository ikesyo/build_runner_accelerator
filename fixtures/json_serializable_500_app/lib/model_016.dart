import 'package:json_annotation/json_annotation.dart';

part 'model_016.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model016 {
  const Model016({required this.id, required this.value});

  final int id;
  final String value;

  factory Model016.fromJson(Map<String, dynamic> json) =>
      _$Model016FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model016ToJson(this);
}
