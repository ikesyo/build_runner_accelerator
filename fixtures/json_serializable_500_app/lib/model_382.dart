import 'package:json_annotation/json_annotation.dart';

part 'model_382.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model382 {
  const Model382({required this.id, required this.value});

  final int id;
  final String value;

  factory Model382.fromJson(Map<String, dynamic> json) =>
      _$Model382FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model382ToJson(this);
}
