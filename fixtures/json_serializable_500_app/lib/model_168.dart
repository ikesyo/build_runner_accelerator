import 'package:json_annotation/json_annotation.dart';

part 'model_168.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model168 {
  const Model168({required this.id, required this.value});

  final int id;
  final String value;

  factory Model168.fromJson(Map<String, dynamic> json) =>
      _$Model168FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model168ToJson(this);
}
