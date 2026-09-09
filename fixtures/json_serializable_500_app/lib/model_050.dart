import 'package:json_annotation/json_annotation.dart';

part 'model_050.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model050 {
  const Model050({required this.id, required this.value});

  final int id;
  final String value;

  factory Model050.fromJson(Map<String, dynamic> json) =>
      _$Model050FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model050ToJson(this);
}
