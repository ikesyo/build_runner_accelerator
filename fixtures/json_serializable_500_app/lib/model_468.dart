import 'package:json_annotation/json_annotation.dart';

part 'model_468.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model468 {
  const Model468({required this.id, required this.value});

  final int id;
  final String value;

  factory Model468.fromJson(Map<String, dynamic> json) =>
      _$Model468FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model468ToJson(this);
}
