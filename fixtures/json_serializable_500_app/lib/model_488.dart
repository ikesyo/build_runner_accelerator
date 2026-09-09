import 'package:json_annotation/json_annotation.dart';

part 'model_488.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model488 {
  const Model488({required this.id, required this.value});

  final int id;
  final String value;

  factory Model488.fromJson(Map<String, dynamic> json) =>
      _$Model488FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model488ToJson(this);
}
