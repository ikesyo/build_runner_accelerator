import 'package:json_annotation/json_annotation.dart';

part 'model_038.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model038 {
  const Model038({required this.id, required this.value});

  final int id;
  final String value;

  factory Model038.fromJson(Map<String, dynamic> json) =>
      _$Model038FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model038ToJson(this);
}
