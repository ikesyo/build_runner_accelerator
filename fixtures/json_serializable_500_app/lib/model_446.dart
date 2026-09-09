import 'package:json_annotation/json_annotation.dart';

part 'model_446.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model446 {
  const Model446({required this.id, required this.value});

  final int id;
  final String value;

  factory Model446.fromJson(Map<String, dynamic> json) =>
      _$Model446FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model446ToJson(this);
}
