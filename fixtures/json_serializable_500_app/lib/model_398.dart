import 'package:json_annotation/json_annotation.dart';

part 'model_398.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model398 {
  const Model398({required this.id, required this.value});

  final int id;
  final String value;

  factory Model398.fromJson(Map<String, dynamic> json) =>
      _$Model398FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model398ToJson(this);
}
