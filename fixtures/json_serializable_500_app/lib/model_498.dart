import 'package:json_annotation/json_annotation.dart';

part 'model_498.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model498 {
  const Model498({required this.id, required this.value});

  final int id;
  final String value;

  factory Model498.fromJson(Map<String, dynamic> json) =>
      _$Model498FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model498ToJson(this);
}
